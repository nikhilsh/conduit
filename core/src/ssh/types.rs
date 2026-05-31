//! Public + crate-visible types for the SSH-bootstrap flow.
//!
//! Smaller than litter's equivalent because we drive a single remote
//! command (`scripts/remote-bootstrap.sh`) over a single transport
//! (WebSocket on 1977 inside the docker container) — no shell detection,
//! no app-server proxy / WebSocket-tunnel branching, no binary
//! discovery.

use thiserror::Error;

/// Credentials the mobile app collects from the user to open an SSH
/// session against their server.
#[derive(Clone, Debug)]
pub struct SshCredentials {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: SshAuth,
}

/// Authentication method. We deliberately don't surface SSH-agent
/// forwarding on the mobile side — passing `SSH_AUTH_SOCK` from iOS is
/// fraught and most users will paste a key or use a password.
#[derive(Clone, Debug)]
pub enum SshAuth {
    Password {
        password: String,
    },
    PrivateKey {
        key_pem: String,
        passphrase: Option<String>,
    },
}

/// Outcome of [`crate::ssh::SshClient::bootstrap`].
#[derive(Clone, Debug)]
pub struct SshBootstrapResult {
    /// Remote port the harness is bound to inside the SSH tunnel. The
    /// mobile transport connects to `ws://127.0.0.1:{local_port}` and
    /// the SSH session forwards to this remote port.
    pub remote_port: u16,
    /// Local TCP port the SSH layer is listening on (the tunnel
    /// endpoint the mobile WebSocket transport connects to).
    pub local_port: u16,
    /// Bearer token the harness accepts. Either the value the caller
    /// passed in (via the `CONDUIT_TOKEN` env on the remote container)
    /// or — if we found an existing reusable container — the bearer
    /// that container was started with.
    pub token: String,
    /// SHA-256 fingerprint of the remote host's SSH public key. The
    /// platform layer records this on first successful bootstrap so
    /// subsequent reconnects can refuse silently changed keys (TOFU).
    pub host_key_fingerprint: String,
    /// True if we attached to a container the previous bootstrap
    /// started; false if we ran a fresh `docker run`.
    pub reused: bool,
}

/// Structured errors the mobile layer can present meaningfully. Codes
/// 11–15 mirror `scripts/remote-bootstrap.sh`'s exit code contract.
#[derive(Debug, Error)]
pub enum SshError {
    #[error("tcp dial failed: {0}")]
    Dial(String),
    #[error("ssh handshake failed: {0}")]
    Handshake(String),
    #[error("host key rejected: {fingerprint}")]
    HostKeyRejected { fingerprint: String },
    #[error("authentication failed (check username + key/password)")]
    AuthFailed,
    #[error("docker is not installed on the remote host")]
    DockerMissing,
    #[error("remote user cannot run docker without sudo")]
    DockerPermission,
    #[error("remote port {0} is already in use by a non-conduit process")]
    PortConflict(u16),
    #[error("harness container failed to become healthy within 30s")]
    HarnessStartTimeout,
    #[error("remote bootstrap exited with code {code}: {stderr}")]
    BootstrapExitCode { code: i32, stderr: String },
    #[error("remote bootstrap output not understood: {0}")]
    BootstrapParse(String),
    #[error("port-forward failed: {0}")]
    PortForward(String),
    #[error("io error: {0}")]
    Io(String),
}

impl SshError {
    /// Map the bootstrap script's exit code → typed error. Anything we
    /// don't recognise becomes `BootstrapExitCode` with the raw stderr.
    pub(crate) fn from_bootstrap_exit(code: i32, stderr: String) -> Self {
        match code {
            11 => SshError::DockerMissing,
            12 => SshError::DockerPermission,
            13 => SshError::HarnessStartTimeout,
            14 => SshError::PortConflict(parse_port_from_msg(&stderr).unwrap_or(1977)),
            _ => SshError::BootstrapExitCode { code, stderr },
        }
    }
}

fn parse_port_from_msg(msg: &str) -> Option<u16> {
    // bootstrap.sh emits "ERR 14 host port <N> already in use ..."
    // Skip everything up to the "port" word so we don't match the
    // error code itself (14).
    let mut found_port_word = false;
    for tok in msg.split_ascii_whitespace() {
        if tok.eq_ignore_ascii_case("port") {
            found_port_word = true;
            continue;
        }
        if found_port_word {
            if let Ok(n) = tok.parse::<u16>() {
                return Some(n);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_bootstrap_exit_maps_known_codes() {
        assert!(matches!(
            SshError::from_bootstrap_exit(11, "docker not installed".into()),
            SshError::DockerMissing
        ));
        assert!(matches!(
            SshError::from_bootstrap_exit(12, "no permission".into()),
            SshError::DockerPermission
        ));
        assert!(matches!(
            SshError::from_bootstrap_exit(13, "timeout".into()),
            SshError::HarnessStartTimeout
        ));
        match SshError::from_bootstrap_exit(14, "ERR 14 host port 1977 already in use".into()) {
            SshError::PortConflict(p) => assert_eq!(p, 1977),
            other => panic!("expected PortConflict, got {other:?}"),
        }
    }

    #[test]
    fn from_bootstrap_exit_keeps_unknown_as_typed_exit() {
        match SshError::from_bootstrap_exit(99, "weird".into()) {
            SshError::BootstrapExitCode { code, stderr } => {
                assert_eq!(code, 99);
                assert_eq!(stderr, "weird");
            }
            other => panic!("expected BootstrapExitCode, got {other:?}"),
        }
    }
}
