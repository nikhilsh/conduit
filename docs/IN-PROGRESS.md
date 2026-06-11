# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Push-driven Live Activities** — iOS + broker; drive lock-screen
  turn-progress Live Activities via APNs push rather than polling.
- **Fast-mode toggle** — iOS + Android; make the `supportsFastMode` label
  actionable (iOS is read-only today; Android has nothing).
- **Codex extra approval/elicitation cards** — app-side card rendering for
  `item/fileChange/requestApproval`, `item/tool/requestUserInput`, and
  `mcpServer/elicitation/request`; investigating whether app UI covers these
  types or rendering is missing.
- **UnifiedPush ntfy Android auto-config** — wire the `features.ntfy_url`
  advertised by `--with-ntfy` bootstrap into Android UnifiedPush registration
  without Firebase.
- **Per-identity readiness/push** — make `signed_in` readiness per-bearer
  rather than box-global; needed for shared boxes.
- **VPS backup helper** — `scripts/conduit-backup.sh` + `docs/BACKUP-RECOVERY.md`
  shipped in this PR; verify by running the script on the live box.
