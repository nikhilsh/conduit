package sh.nikhil.conduit

import android.net.Uri

/** Parse pairing URL from QR.
 * Supports:
 *  - `conduit://host[:port]?token=<bearer>`
 *  - `ws[s]://host[:port]?token=<bearer>`
 */
object PairingURL {
    data class Parsed(val endpoint: String, val token: String)

    fun parse(raw: String): Parsed? {
        val uri = runCatching { Uri.parse(raw) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host ?: return null
        val token = uri.getQueryParameter("token").orEmpty()
        if (token.isBlank()) return null
        val port = if (uri.port > 0) ":${uri.port}" else ""
        return when (scheme) {
            "conduit" -> Parsed(endpoint = "ws://$host$port", token = token)
            "ws", "wss" -> Parsed(endpoint = "$scheme://$host$port", token = token)
            else -> null
        }
    }
}
