package sh.nikhil.swekitty.auth

import android.net.Uri
import android.util.Log
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Android mirror of iOS `AgentLoginLoopbackServer.swift`
 * (PLAN-AGENT-OAUTH.md "Approach v2" / Stage 3).
 *
 * Tiny HTTP listener bound to `127.0.0.1:<port>` for the duration of
 * a single agent-login attempt. The provider's OAuth flow redirects
 * the user's browser to `http://localhost:<port>/auth/callback?code=…`
 * at the end of the consent step; this listener catches that GET,
 * extracts the query string, and fires the supplied `onCallback`
 * with the URL components.
 *
 * Design choices (verbatim from the iOS doc — kept identical so the
 * two platforms can't drift):
 *
 *  - Bind `127.0.0.1` only (not `localhost`, not `::1`) so we never
 *    accidentally accept a non-loopback connection. The provider's
 *    redirect lives in the same browser-app sandbox as the user;
 *    only a same-device adversary could even attempt to race the
 *    listener, and on Android that's effectively the user themselves.
 *  - 600 s timeout matches litter's `callbackTimeout` and the codex
 *    CLI's patience window on the broker side.
 *  - One-shot semantics: the first valid `GET <path>?…` resolves
 *    the listener and stops it. A second hit (browser retried) gets
 *    a friendly HTML page but does not re-fire `onCallback`.
 *  - HTTP only — never HTTPS. The provider's redirect_uri whitelist
 *    explicitly lists `http://localhost:<port>/auth/callback`, and a
 *    self-signed cert on the loopback listener would just confuse
 *    the system browser.
 *
 * Stage 3 scope: shape + start/stop lifecycle + pure parser. Wiring
 * into the live Sheet (Chrome Custom Tabs intent) is a follow-up.
 */
class AgentLoginLoopbackServer(
    /** Port to bind. Mirrors `loopback_port` from the broker's `agent_login_url` view_event. */
    val port: Int,
    /** Path the listener accepts. Anything else gets a 404. */
    val path: String = "/auth/callback",
) {
    /**
     * Result of a single captured callback. The phone forwards
     * [rawQueryString] to the broker verbatim; the broker normalises
     * `code` / `state` / `error` itself when it Dials the CLI's
     * loopback.
     */
    data class CallbackResult(
        /**
         * The raw `?…` segment of the captured GET request — empty
         * when the redirect carried no query. Preserves percent-
         * encoding for round-trip fidelity.
         */
        val rawQueryString: String,
        /** Parsed `code` query item value (empty when absent). */
        val code: String,
        /** Parsed `error` query item value (empty when absent). */
        val errorReason: String,
    )

    private val lock = Any()
    private var serverSocket: ServerSocket? = null
    private var didDeliver = false
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "swe-kitty-agent-login-loopback").apply { isDaemon = true }
    }

    /**
     * Binds the listener and arms it for one callback delivery.
     * [onCallback] fires when a matching `GET <path>?…` arrives (or
     * on timeout). Errors at bind time bubble out as a throw.
     */
    @Throws(IOException::class)
    fun start(
        timeoutMillis: Long = TimeUnit.SECONDS.toMillis(600),
        onCallback: (Result<CallbackResult>) -> Unit,
    ) {
        val sock = ServerSocket(port, /* backlog = */ 1, InetAddress.getByName("127.0.0.1"))
        sock.soTimeout = timeoutMillis.toInt().coerceAtLeast(0)
        synchronized(lock) {
            serverSocket = sock
            didDeliver = false
        }
        executor.execute {
            try {
                val client: Socket = sock.accept()
                client.use { handle(it, onCallback) }
            } catch (_: java.net.SocketTimeoutException) {
                fireOnce(Result.failure(AgentLoginLoopbackError.TimedOut), onCallback)
            } catch (t: Throwable) {
                Log.w(TAG, "loopback accept failed", t)
                fireOnce(Result.failure(t), onCallback)
            }
        }
    }

    /**
     * Tear the listener down. Idempotent; subsequent `onCallback`
     * invocations are suppressed by [didDeliver].
     */
    fun stop() {
        val sock: ServerSocket? = synchronized(lock) {
            val s = serverSocket
            serverSocket = null
            didDeliver = true
            s
        }
        runCatching { sock?.close() }
        executor.shutdownNow()
    }

    private fun handle(client: Socket, onCallback: (Result<CallbackResult>) -> Unit) {
        val reader = BufferedReader(InputStreamReader(client.getInputStream()))
        val requestLine = reader.readLine().orEmpty()
        val result = parseRequestLine(requestLine, expectedPath = path)
        if (result == null) {
            respond(client, "HTTP/1.1 404 Not Found", "Not found")
            return
        }
        respond(
            client,
            "HTTP/1.1 200 OK",
            "<html><body><h3>Sign-in complete</h3><p>You can return to the SweKitty app.</p></body></html>",
        )
        fireOnce(Result.success(result), onCallback)
    }

    private fun respond(client: Socket, statusLine: String, body: String) {
        val bodyBytes = body.toByteArray(Charsets.UTF_8)
        val header = buildString {
            append(statusLine).append("\r\n")
            append("Content-Type: text/html; charset=UTF-8\r\n")
            append("Connection: close\r\n")
            append("Content-Length: ").append(bodyBytes.size).append("\r\n\r\n")
        }
        runCatching {
            client.getOutputStream().apply {
                write(header.toByteArray(Charsets.UTF_8))
                write(bodyBytes)
                flush()
            }
        }
    }

    private fun fireOnce(result: Result<CallbackResult>, onCallback: (Result<CallbackResult>) -> Unit) {
        val shouldDeliver = synchronized(lock) {
            if (didDeliver) false
            else {
                didDeliver = true
                serverSocket?.let { runCatching { it.close() } }
                serverSocket = null
                true
            }
        }
        if (shouldDeliver) onCallback(result)
    }

    companion object {
        private const val TAG = "AgentLoginLoopback"

        /**
         * Pure-function parser for an HTTP request line. Exposed so
         * the test layer can drive it without binding a real socket.
         * Mirrors `AgentLoginLoopbackServer.parseRequestLine` on iOS.
         */
        fun parseRequestLine(line: String, expectedPath: String): CallbackResult? {
            // RFC 7230 request line: `<METHOD> <target> <HTTP/version>`
            val parts = line.split(' ').filter { it.isNotEmpty() }
            if (parts.size < 2) return null
            // We only accept GET — any provider redirect is a GET.
            if (parts[0] != "GET") return null
            val target = parts[1]
            // Split target into <path>?<query>
            val qIdx = target.indexOf('?')
            val pathOnly = if (qIdx >= 0) target.substring(0, qIdx) else target
            if (pathOnly != expectedPath) return null
            val query = if (qIdx >= 0 && qIdx + 1 < target.length) target.substring(qIdx + 1) else ""
            var code = ""
            var errorReason = ""
            if (query.isNotEmpty()) {
                // Wrap in a `http://l/?…` so `Uri.parse` does the
                // percent-decoding for us; `Uri.getQueryParameter`
                // matches the way the iOS side calls `URLComponents`.
                val uri = Uri.parse("http://l/?$query")
                code = uri.getQueryParameter("code").orEmpty()
                errorReason = uri.getQueryParameter("error").orEmpty()
            }
            return CallbackResult(rawQueryString = query, code = code, errorReason = errorReason)
        }
    }
}

sealed class AgentLoginLoopbackError(message: String) : Exception(message) {
    data object TimedOut : AgentLoginLoopbackError("Sign-in timed out before the browser redirected back.")
}
