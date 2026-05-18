package sh.nikhil.swekitty

import android.net.Uri

/** Parse `swekitty://host[:port]?token=<bearer>` from a scanned QR. */
object PairingURL {
    data class Parsed(val endpoint: String, val token: String)

    fun parse(raw: String): Parsed? {
        val uri = runCatching { Uri.parse(raw) }.getOrNull() ?: return null
        if (!uri.scheme.equals("swekitty", ignoreCase = true)) return null
        val host = uri.host ?: return null
        val token = uri.getQueryParameter("token").orEmpty()
        if (token.isBlank()) return null
        val port = if (uri.port > 0) ":${uri.port}" else ""
        return Parsed(endpoint = "ws://$host$port", token = token)
    }
}
