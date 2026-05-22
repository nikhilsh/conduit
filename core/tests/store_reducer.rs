//! End-to-end coverage for `core::store::SessionStoreCore`.
//!
//! These are public-API tests so they double as the worked example for
//! the iOS/Android `SessionStore.{swift,kt}` shells once the migration
//! Plan §3.1 lands. Each test mirrors one of the existing platform-side
//! reducer paths (`ingestChat` / `ingestStatus` / `ingestExit` / …).
//!
//! Idempotency and ordering live here too because both platforms relied
//! on ad-hoc deduplication; the store is now the single guard.

use swe_kitty_core::store::{SessionLifecycleCore, SessionStoreCore};
use swe_kitty_core::{ChatEvent, PreviewInfo, ProjectSession, SessionStatus, ViewEventFile};

fn project(id: &str, assistant: &str) -> ProjectSession {
    ProjectSession {
        id: id.to_string(),
        name: id.to_string(),
        assistant: assistant.to_string(),
        branch: None,
        preview: None,
        reasoning_effort: None,
        cwd: None,
        started_at: None,
        last_activity_at: None,
        display_name: None,
    }
}

fn chat(role: &str, content: &str, ts: &str) -> ChatEvent {
    ChatEvent {
        role: role.to_string(),
        content: content.to_string(),
        ts: ts.to_string(),
        files: vec![],
    }
}

fn status(
    session: &str,
    phase: &str,
    health: &str,
    effort: Option<&str>,
    name: Option<&str>,
) -> SessionStatus {
    SessionStatus {
        session: session.to_string(),
        assistant: "claude".to_string(),
        phase: phase.to_string(),
        health: health.to_string(),
        rows: 24,
        cols: 80,
        yolo: false,
        preview: None,
        session_name: name.map(|s| s.to_string()),
        viewers: None,
        reasoning_effort: effort.map(|s| s.to_string()),
        cwd: None,
        started_at: None,
        last_activity_at: None,
        display_name: None,
    }
}

#[test]
fn full_session_lifecycle_user_assistant_tool_diff_exit() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    store.apply_lifecycle("s1".to_string(), SessionLifecycleCore::Creating);

    store.apply_status(status(
        "s1",
        "live",
        "green",
        Some("medium"),
        Some("Fix #42"),
    ));
    assert_eq!(
        store.lifecycle("s1".to_string()),
        Some(SessionLifecycleCore::Live)
    );

    store.apply_chat(
        "s1".to_string(),
        chat("user", "Fix the off-by-one", "2026-05-21T00:00:00Z"),
    );
    store.apply_chat(
        "s1".to_string(),
        chat("assistant", "Looking at the loop", "2026-05-21T00:00:01Z"),
    );
    store.apply_chat(
        "s1".to_string(),
        chat(
            "tool",
            "Bash: cargo test\nduration: 1.5s\nexit code: 0",
            "2026-05-21T00:00:02Z",
        ),
    );
    store.apply_chat(
        "s1".to_string(),
        chat(
            "tool",
            "diff --git a/foo.rs b/foo.rs\n@@ -1 +1 @@\n-old\n+new",
            "2026-05-21T00:00:03Z",
        ),
    );

    let snap = store.apply_exit("s1".to_string(), 0).unwrap();
    assert!(snap.exited);
    assert_eq!(snap.chat.conversation.len(), 4);
    assert_eq!(snap.chat.conversation[0].kind, "message");
    assert_eq!(snap.chat.conversation[2].kind, "tool");
    assert_eq!(snap.chat.conversation[2].tool_name.as_deref(), Some("Bash"));
    assert_eq!(snap.chat.conversation[2].duration_ms, Some(1500));
    assert_eq!(snap.chat.conversation[3].kind, "diff");
    assert!(snap.chat.conversation[3].diff_summary.is_some());
    assert_eq!(snap.session.name, "Fix #42");
    assert_eq!(snap.session.reasoning_effort.as_deref(), Some("medium"));
    assert_eq!(
        store.lifecycle("s1".to_string()),
        Some(SessionLifecycleCore::Exited { code: 0 })
    );
}

#[test]
fn idempotent_replay_after_reconnect() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    // Simulate the broker re-sending the same three events after a
    // reconnect (the reconnect worker doesn't dedupe — that's our job).
    for _ in 0..3 {
        store.apply_chat(
            "s1".to_string(),
            chat("user", "do it", "2026-05-21T00:00:00Z"),
        );
        store.apply_chat(
            "s1".to_string(),
            chat("assistant", "ok", "2026-05-21T00:00:01Z"),
        );
        store.apply_status(status("s1", "live", "green", Some("high"), None));
    }
    let snap = store.get("s1".to_string()).unwrap();
    assert_eq!(snap.chat.events.len(), 2, "duplicates collapsed");
    assert_eq!(snap.chat.conversation.len(), 2);
    assert_eq!(snap.session.reasoning_effort.as_deref(), Some("high"));
}

#[test]
fn out_of_order_chat_before_status_for_unknown_session() {
    let store = SessionStoreCore::new();
    // No register_session: the broker shipped a status for a session
    // the platform layer didn't know about yet (live join from another
    // device, for example). apply_status should still install the
    // placeholder so subsequent chats fold in.
    store.apply_status(status(
        "s_remote",
        "live",
        "green",
        Some("low"),
        Some("alt"),
    ));
    store
        .apply_chat(
            "s_remote".to_string(),
            chat("assistant", "joining…", "2026-05-21T00:00:00Z"),
        )
        .expect("session synthesized from status frame");
    let snap = store.get("s_remote".to_string()).unwrap();
    assert_eq!(snap.session.name, "alt");
    assert_eq!(snap.chat.conversation.len(), 1);
}

#[test]
fn pending_input_options_extracted_via_chat_classifier() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    store
        .apply_chat(
            "s1".to_string(),
            chat(
                "assistant",
                "Which? \n1. Yes\n2. Yes, don't ask\n3. No",
                "2026-05-21T00:00:00Z",
            ),
        )
        .unwrap();
    let snap = store.get("s1".to_string()).unwrap();
    let item = &snap.chat.conversation[0];
    assert_eq!(item.kind, "pending_input");
    assert_eq!(item.pending_options.len(), 3);
}

#[test]
fn preview_updates_both_session_and_browser_view() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    store
        .apply_preview(
            "s1".to_string(),
            PreviewInfo {
                port: 3000,
                url: "http://127.0.0.1:3000".to_string(),
            },
        )
        .unwrap();
    let snap = store.get("s1".to_string()).unwrap();
    assert_eq!(snap.browser.preview.as_ref().unwrap().port, 3000);
    assert_eq!(snap.session.preview.as_ref().unwrap().port, 3000);
}

#[test]
fn snapshot_replaces_subsequent_pty_appends() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    store.apply_pty_data("s1".to_string(), b"junk before reconnect".to_vec());
    store.apply_snapshot("s1".to_string(), b"authoritative".to_vec());
    let snap = store
        .apply_pty_data("s1".to_string(), b" + more".to_vec())
        .unwrap();
    assert_eq!(snap.terminal.scrollback, b"authoritative + more");
    assert!(snap.terminal.has_snapshot);
}

#[test]
fn chat_with_files_preserves_view_event_files() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    let event = ChatEvent {
        role: "tool".to_string(),
        content: "Edit: lib.rs".to_string(),
        ts: "2026-05-21T00:00:00Z".to_string(),
        files: vec![ViewEventFile {
            path: "src/lib.rs".to_string(),
            rev: "rev-1".to_string(),
        }],
    };
    let snap = store.apply_chat("s1".to_string(), event).unwrap();
    let item = &snap.chat.conversation[0];
    assert_eq!(item.files.len(), 1);
    assert_eq!(item.files[0].path, "src/lib.rs");
}

#[test]
fn exit_non_zero_promotes_health_to_dead() {
    let store = SessionStoreCore::new();
    store.register_session(project("s1", "claude"));
    store.apply_status(status("s1", "live", "green", None, None));
    let snap = store.apply_exit("s1".to_string(), 137).unwrap();
    assert_eq!(snap.status.unwrap().health, "dead");
    assert_eq!(
        store.lifecycle("s1".to_string()),
        Some(SessionLifecycleCore::Exited { code: 137 })
    );
}

#[test]
fn lifecycle_failed_to_start_persists_until_overwrite() {
    let store = SessionStoreCore::new();
    store.apply_lifecycle("pending-1".to_string(), SessionLifecycleCore::Creating);
    store.apply_lifecycle(
        "pending-1".to_string(),
        SessionLifecycleCore::FailedToStart {
            reason: "auth".to_string(),
        },
    );
    assert_eq!(
        store.lifecycle("pending-1".to_string()),
        Some(SessionLifecycleCore::FailedToStart {
            reason: "auth".to_string(),
        })
    );
}
