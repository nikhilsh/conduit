//! SSH-bootstrap for the mobile pairing flow.
//!
//! The mobile-side Rust core opens an SSH session against the user's
//! server (russh), uploads `scripts/remote-bootstrap.sh` via stdin to
//! a remote `sh`, parses the OK/ERR output, then sets up a local TCP
//! listener that forwards into the same SSH session via russh's
//! `direct-tcpip` channel type. The mobile WebSocket transport
//! connects to that local port unchanged.
//!
//! Architectural notes:
//! - Single transport (WebSocket on 1977 in the Docker container) —
//!   we don't need upstream's app-server-proxy vs WS-tunnel branching.
//! - Single remote shell (POSIX) — we're targeting the harness's
//!   own Docker image, hosted on a Linux server. PowerShell, NU, etc.
//!   are out of scope.
//! - Bootstrap script embedded via `include_str!` so there's no
//!   "upload the script first" round trip — `sh -s` reads it from
//!   stdin on the same exec channel.

mod bootstrap;
mod connect;
mod port_forward;
mod tunnel;
mod types;

pub use tunnel::SshTunnel;
pub use types::{SshAuth, SshBootstrapResult, SshCredentials, SshError, SshTunnelBootstrap};

pub use connect::HostKeyCallback;
use connect::SshClient;

/// Embedded copy of `scripts/remote-bootstrap.sh`. We bake it into the
/// binary so the mobile clients ship a known, version-locked script —
/// no risk of an old phone running a stale bootstrap against a freshly
/// updated harness.
const REMOTE_BOOTSTRAP_SH: &str = include_str!("../../../scripts/remote-bootstrap.sh");

/// Drive the end-to-end SSH bootstrap and return the pairing target.
///
/// On success the returned [`SshBootstrapResult::local_port`] is a
/// localhost TCP port that's now SSH-forwarded to the harness container
/// inside the user's server. Mobile transport calls
/// `connect("ws://127.0.0.1:{local_port}", token)` and is on the air.
///
/// Back-compat shape: this spawns a fire-and-forget tunnel and **drops** the
/// owning [`SshTunnel`] handle, matching the pre-tunnel-handle behaviour. The
/// accept loop + russh session stay alive (the spawned tasks hold their own
/// `Arc`s), so the forward keeps working — but the caller gets no way to stop
/// it or observe liveness. Prefer [`ssh_bootstrap_tunneled`] for new code.
pub async fn ssh_bootstrap(
    creds: SshCredentials,
    pre_allocated_token: String,
    anthropic_api_key: String,
    openai_api_key: String,
    image_ref: Option<String>,
    host_key_cb: HostKeyCallback,
) -> Result<SshBootstrapResult, SshError> {
    let bootstrap = ssh_bootstrap_tunneled(
        creds,
        pre_allocated_token,
        anthropic_api_key,
        openai_api_key,
        image_ref,
        host_key_cb,
    )
    .await?;
    // Detach the tunnel: forget the handle so the accept loop / watcher keep
    // running for the process lifetime (legacy behaviour). std::mem::forget
    // would leak the Arc; instead we deliberately leak only the strong ref by
    // converting into the raw Arc and forgetting it, so Drop (which aborts the
    // tasks) never fires.
    std::mem::forget(bootstrap.tunnel);
    Ok(bootstrap.result)
}

/// Bootstrap **and** return the owned [`SshTunnel`] so the caller controls its
/// lifecycle: hold the handle for the pairing's lifetime, observe
/// [`SshTunnel::is_alive`], and call [`SshTunnel::stop`] on logout/teardown.
///
/// This is the path the apps should migrate to (see
/// `docs/PLAN-SSH-TUNNEL.md`).
pub async fn ssh_bootstrap_tunneled(
    creds: SshCredentials,
    pre_allocated_token: String,
    anthropic_api_key: String,
    openai_api_key: String,
    image_ref: Option<String>,
    host_key_cb: HostKeyCallback,
) -> Result<SshTunnelBootstrap, SshError> {
    if pre_allocated_token.len() < 16 {
        return Err(SshError::BootstrapParse(
            "pre_allocated_token must be at least 16 chars".into(),
        ));
    }

    let client = SshClient::connect(creds.clone(), host_key_cb).await?;
    let parsed = run_remote_bootstrap(
        &client,
        &pre_allocated_token,
        &anthropic_api_key,
        &openai_api_key,
        image_ref.as_deref(),
    )
    .await?;

    // Bind a local listener — port chosen by the kernel — and spawn the owned
    // tunnel (accept loop forwards each accept onto a direct-tcpip channel to
    // the remote harness port; a watcher trips teardown if the session dies).
    let (listener, local_port) = port_forward::bind_random_local().await?;
    let handle = std::sync::Arc::clone(&client.handle);
    let remote_port = parsed.port;
    let tunnel = SshTunnel::spawn(handle, listener, local_port, remote_port);

    Ok(SshTunnelBootstrap {
        result: SshBootstrapResult {
            remote_port: parsed.port,
            local_port,
            token: parsed.token,
            host_key_fingerprint: client.host_key_fingerprint,
            reused: parsed.reused,
        },
        tunnel,
    })
}

/// Open an SSH exec channel running `sh -s -- <args>`, pipe the
/// embedded bootstrap script in on stdin, collect stdout + the exit
/// status, then hand the captured stdout to [`bootstrap::parse_output`].
async fn run_remote_bootstrap(
    client: &SshClient,
    token: &str,
    anthropic: &str,
    openai: &str,
    image_ref: Option<&str>,
) -> Result<bootstrap::ParsedBootstrap, SshError> {
    let args = [
        shell_quote(token),
        shell_quote(anthropic),
        shell_quote(openai),
        shell_quote(image_ref.unwrap_or("")),
    ];
    let command = format!("sh -s -- {}", args.join(" "));
    let handle = client.handle.lock().await;
    let mut channel = handle
        .channel_open_session()
        .await
        .map_err(|e| SshError::Handshake(e.to_string()))?;
    channel
        .exec(true, command.as_bytes())
        .await
        .map_err(|e| SshError::Handshake(e.to_string()))?;

    // Stream the embedded script into the channel's stdin.
    channel
        .data(REMOTE_BOOTSTRAP_SH.as_bytes())
        .await
        .map_err(|e| SshError::Io(e.to_string()))?;
    channel
        .eof()
        .await
        .map_err(|e| SshError::Io(e.to_string()))?;

    let mut stdout = String::new();
    let mut stderr = String::new();
    let mut exit_code: Option<i32> = None;
    while let Some(msg) = channel.wait().await {
        match msg {
            russh::ChannelMsg::Data { ref data } => stdout.push_str(&String::from_utf8_lossy(data)),
            russh::ChannelMsg::ExtendedData { ref data, .. } => {
                stderr.push_str(&String::from_utf8_lossy(data))
            }
            russh::ChannelMsg::ExitStatus { exit_status } => exit_code = Some(exit_status as i32),
            russh::ChannelMsg::Eof | russh::ChannelMsg::Close => {}
            _ => {}
        }
    }

    // Parse first — the OK/ERR contract is on stdout. If the script
    // exited cleanly but stdout had no OK/ERR, parse_output will return
    // SshError::BootstrapParse and we'll fall through to the stderr
    // path below to enrich the message.
    let parse_attempt = bootstrap::parse_output(&stdout);
    match (parse_attempt, exit_code) {
        (Ok(p), _) => Ok(p),
        (Err(SshError::BootstrapParse(msg)), Some(code)) if code != 0 => Err(
            SshError::from_bootstrap_exit(code, format!("{msg}; stderr={stderr}")),
        ),
        (Err(e), _) => Err(e),
    }
}

/// POSIX single-quote-safe shell quoting for arguments we splice into a
/// remote `sh -s -- …` invocation.
fn shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_round_trips() {
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("simple"), "'simple'");
        assert_eq!(shell_quote("with space"), "'with space'");
        assert_eq!(shell_quote("with'quote"), "'with'\\''quote'");
    }
}
