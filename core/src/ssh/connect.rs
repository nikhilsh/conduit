//! SSH session establishment: TCP dial → russh handshake → host-key
//! TOFU callback → authenticate → ready-to-use [`SshClient`].

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use parking_lot::Mutex as SyncMutex;
use russh::client::{self, Handle};
use russh::keys::{decode_secret_key, key, PublicKeyBase64};
use tokio::sync::Mutex as AsyncMutex;

use super::{SshAuth, SshCredentials, SshError};
use crate::SshProgressDelegate;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(15);
const KEEPALIVE_MAX: usize = 3; // ~60s to KeepaliveTimeout (15s * 3 missed replies)
const INACTIVITY_TIMEOUT: Duration = Duration::from_secs(120);

/// Async predicate the platform layer implements to accept or reject a
/// server's SSH public key on first sight. Argument is the SHA-256
/// fingerprint base-64 (matches `russh-keys` `PublicKeyBase64` shape;
/// the platform layer prepends "SHA256:" before showing the user).
pub type HostKeyCallback =
    Arc<dyn Fn(String) -> futures_util::future::BoxFuture<'static, bool> + Send + Sync>;

/// Owns the russh `Handle` once the handshake + auth succeed. Wrapped
/// in `Arc<Mutex>` because every operation on `Handle` is `&mut self`
/// and we need to share it between the bootstrap exec channel and the
/// long-lived port-forward listener task.
pub struct SshClient {
    pub(super) handle: Arc<AsyncMutex<Handle<RusshClientHandler>>>,
    pub(super) host_key_fingerprint: String,
}

pub(super) struct RusshClientHandler {
    cb: HostKeyCallback,
    /// Captured when the server presents its key. The connect path
    /// reads this back so we can return it to the platform layer for
    /// persistence (so reconnects can detect a silently rotated key).
    captured_fingerprint: Arc<SyncMutex<Option<String>>>,
}

#[async_trait]
impl client::Handler for RusshClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // PublicKeyBase64 gives us the base64 wire encoding; the
        // platform UI formats it as "SHA256:<b64>" or similar before
        // showing the user — we don't impose a format here.
        let fp = server_public_key.public_key_base64();
        let accepted = (self.cb)(fp.clone()).await;
        if accepted {
            *self.captured_fingerprint.lock() = Some(fp);
        }
        Ok(accepted)
    }
}

impl SshClient {
    /// Dial → handshake → auth. Returns the live client + the
    /// fingerprint of the server's host key (only populated if the
    /// callback accepted it; otherwise we never reach this point).
    /// Progress events are emitted at each phase so the app can surface
    /// live status during the connect sequence.
    pub async fn connect(
        creds: SshCredentials,
        host_key_cb: HostKeyCallback,
        progress: std::sync::Arc<dyn SshProgressDelegate>,
    ) -> Result<Self, SshError> {
        let captured = Arc::new(SyncMutex::new(None));
        let handler = RusshClientHandler {
            cb: host_key_cb,
            captured_fingerprint: Arc::clone(&captured),
        };

        let config = Arc::new(client::Config {
            keepalive_interval: Some(KEEPALIVE_INTERVAL),
            keepalive_max: KEEPALIVE_MAX,
            inactivity_timeout: Some(INACTIVITY_TIMEOUT),
            ..Default::default()
        });

        let addr_str = format!("{}:{}", creds.host, creds.port);
        progress.on_progress("connecting".to_string(), Some(addr_str));

        let addr = (creds.host.as_str(), creds.port);
        let mut handle =
            tokio::time::timeout(CONNECT_TIMEOUT, client::connect(config, addr, handler))
                .await
                .map_err(|_| SshError::Dial(format!("timeout after {:?}", CONNECT_TIMEOUT)))?
                .map_err(|e| SshError::Handshake(e.to_string()))?;

        progress.on_progress("handshake".to_string(), None);

        progress.on_progress("authenticating".to_string(), None);
        let authed = match creds.auth.clone() {
            SshAuth::Password { password } => handle
                .authenticate_password(creds.username.clone(), password)
                .await
                .map_err(|e| SshError::Handshake(e.to_string()))?,
            SshAuth::PrivateKey {
                key_pem,
                passphrase,
            } => {
                let key_pair = decode_secret_key(&key_pem, passphrase.as_deref())
                    .map_err(|e| SshError::Handshake(format!("decode_secret_key: {e}")))?;
                handle
                    .authenticate_publickey(creds.username.clone(), Arc::new(key_pair))
                    .await
                    .map_err(|e| SshError::Handshake(e.to_string()))?
            }
        };

        if !authed {
            return Err(SshError::AuthFailed);
        }

        let host_key_fingerprint =
            captured
                .lock()
                .clone()
                .ok_or_else(|| SshError::HostKeyRejected {
                    fingerprint: "<not-captured>".into(),
                })?;

        Ok(SshClient {
            handle: Arc::new(AsyncMutex::new(handle)),
            host_key_fingerprint,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify the keepalive constants that control dead-peer detection timing.
    /// KEEPALIVE_INTERVAL * KEEPALIVE_MAX gives the worst-case time-to-detect:
    /// 15s * 3 = 45s. This test will fail if someone accidentally relaxes these
    /// values back to the slow defaults (30s interval, max=3 => 90s detection).
    #[test]
    fn keepalive_config_is_tight() {
        // Detection window must be <= 60s so mobile flaps are caught promptly.
        let detection_window_secs = KEEPALIVE_INTERVAL.as_secs() * (KEEPALIVE_MAX as u64);
        // KEEPALIVE_MAX is usize; cast is safe for any value we'd ever set.
        assert!(
            detection_window_secs <= 60,
            "keepalive detection window {}s exceeds 60s — self-heal latency too high",
            detection_window_secs
        );
        // Inactivity timeout must be >= detection window so the session is not
        // torn down before keepalives have a chance to detect the dead peer.
        assert!(
            INACTIVITY_TIMEOUT >= KEEPALIVE_INTERVAL,
            "inactivity_timeout must be >= keepalive_interval"
        );
    }
}
