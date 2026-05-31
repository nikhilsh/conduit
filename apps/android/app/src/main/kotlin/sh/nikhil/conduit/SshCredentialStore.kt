package sh.nikhil.conduit

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persisted SSH credential the user has typed once and wants to reuse.
 * Stored in EncryptedSharedPreferences keyed by `user@host:port`.
 * Host-key fingerprints live separately in [SshHostKeyTrustStore] so they
 * can be invalidated without forgetting the password / key.
 */
data class SavedSshCredential(
    val host: String,
    val port: UShort,
    val username: String,
    val kind: Kind,
    /** Plaintext password OR PEM-encoded private key; secret material only. */
    val secret: String,
    /** Only used for [Kind.PrivateKey]. */
    val passphrase: String?,
) {
    enum class Kind { Password, PrivateKey }

    val id: String get() = "$username@$host:$port"
}

/**
 * v1 store: at most one credential per `user@host:port`. Reuses the same
 * encrypted prefs file as the harness endpoint so users can clear all
 * pairing material in one go (app data wipe).
 */
class SshCredentialStore(private val prefs: android.content.SharedPreferences) {

    fun load(): List<SavedSshCredential> {
        val raw = prefs.getString(KEY_INDEX, null).orEmpty()
        if (raw.isBlank()) return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    val kind = SavedSshCredential.Kind.valueOf(
                        o.optString("kind", SavedSshCredential.Kind.Password.name)
                    )
                    add(
                        SavedSshCredential(
                            host = o.optString("host", ""),
                            port = (o.optInt("port", 22).coerceIn(1, 65535)).toUShort(),
                            username = o.optString("username", ""),
                            kind = kind,
                            secret = o.optString("secret", ""),
                            passphrase = o.optString("passphrase", "").ifEmpty { null },
                        )
                    )
                }
            }
        }.getOrElse { emptyList() }
    }

    fun save(cred: SavedSshCredential) {
        val current = load().filterNot { it.id == cred.id } + cred
        persist(current)
    }

    fun remove(id: String) {
        persist(load().filterNot { it.id == id })
    }

    private fun persist(entries: List<SavedSshCredential>) {
        if (entries.isEmpty()) {
            prefs.edit().remove(KEY_INDEX).apply()
            return
        }
        val arr = JSONArray()
        entries.forEach { c ->
            val o = JSONObject()
            o.put("host", c.host)
            o.put("port", c.port.toInt())
            o.put("username", c.username)
            o.put("kind", c.kind.name)
            o.put("secret", c.secret)
            c.passphrase?.let { o.put("passphrase", it) }
            arr.put(o)
        }
        prefs.edit().putString(KEY_INDEX, arr.toString()).apply()
    }

    companion object {
        private const val KEY_INDEX = "conduit.ssh.creds.index"

        /** Builds a store that shares the same encrypted prefs as the endpoint. */
        fun forContext(ctx: Context): SshCredentialStore {
            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                ctx,
                "conduit-ssh",
                master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            return SshCredentialStore(prefs)
        }
    }
}

/**
 * TOFU trust map. Persists `{host:port: fingerprint}` in plain
 * SharedPreferences — re-prompting on a fingerprint change is a deliberate
 * UX signal, not a "default deny" wall, so encryption is overkill.
 */
class SshHostKeyTrustStore(private val prefs: android.content.SharedPreferences) {

    fun known(host: String, port: UShort): String? =
        prefs.getString(key(host, port), null)

    fun trust(host: String, port: UShort, fingerprint: String) {
        prefs.edit().putString(key(host, port), fingerprint).apply()
    }

    fun forget(host: String, port: UShort) {
        prefs.edit().remove(key(host, port)).apply()
    }

    private fun key(host: String, port: UShort) = "$host:$port"

    companion object {
        fun forContext(ctx: Context): SshHostKeyTrustStore {
            return SshHostKeyTrustStore(
                ctx.getSharedPreferences("conduit-knownhosts", Context.MODE_PRIVATE)
            )
        }
    }
}
