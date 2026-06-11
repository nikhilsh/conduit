#!/usr/bin/env bash
set -euo pipefail

# conduit-backup.sh — snapshot tier-1 VPS secrets into a GPG-symmetric archive.
#
# Why this exists:
#   GitHub and Cloudflare secret stores are write-only — you can push a value
#   in but you cannot read it back out.  The APNs .p8 key, the systemd unit
#   (which carries the pinned CONDUIT_TOKEN), and the agent credentials are
#   therefore unrecoverable if the VPS is lost without this backup.
#
# What is captured (items missing on disk are skipped with a note):
#   - APNs auth key      /root/.appstoreconnect/AuthKey_*.p8
#   - systemd unit       /etc/systemd/system/conduit-broker.service
#   - Agent credentials  ~/.claude* / ~/.codex / ~/.gemini (files only)
#   - Sentry config      ~/.config/sentry/auth-token
#   - Cloudflare token   ~/.cloudflare-token
#   - manifest.txt       list of included files + restore notes (generated here)
#
# Output: a single timestamped .tar.gz.gpg (GPG symmetric encryption;
#         passphrase is prompted interactively — NEVER written to disk or logs).
#
# The archive is NEVER transmitted anywhere — it is written locally to $1
# (or the default path printed at startup).
#
# Usage:
#   scripts/conduit-backup.sh [OUTPUT_PATH]
#
# Example:
#   scripts/conduit-backup.sh /media/usb/conduit-backup.tar.gz.gpg

# ── dependency check ─────────────────────────────────────────────────────────

if ! command -v gpg >/dev/null 2>&1; then
  echo "error: gpg is required (apt install gnupg)" >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "error: tar is required" >&2
  exit 1
fi

# ── output path ──────────────────────────────────────────────────────────────

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
DEFAULT_OUT="${HOME}/conduit-backup-${TIMESTAMP}.tar.gz.gpg"
OUTPUT="${1:-$DEFAULT_OUT}"

# Refuse to write to a world-readable location in /tmp (common foot-gun).
case "$OUTPUT" in
  /tmp/*|/var/tmp/*)
    echo "error: OUTPUT_PATH must not be under /tmp or /var/tmp (world-readable)" >&2
    exit 1
    ;;
esac

echo "conduit-backup: output will be written to: $OUTPUT"
echo

# ── staging area (mode 0700 — not world-readable) ────────────────────────────

STAGING="$(mktemp -d)"
chmod 700 "$STAGING"

# Ensure staging is cleaned up on any exit.
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

INCLUDED=()
SKIPPED=()

# ── helper ───────────────────────────────────────────────────────────────────

# stage_file SRC [DEST_SUBDIR]
# Copies SRC into the staging area, preserving path by default, or under
# DEST_SUBDIR when specified.  Glob patterns are expanded by the caller.
stage_file() {
  local src="$1"
  local dest_subdir="${2:-}"
  local dest
  if [[ -n "$dest_subdir" ]]; then
    dest="${STAGING}/${dest_subdir}/$(basename "$src")"
    mkdir -p "$(dirname "$dest")"
  else
    # Strip leading / to create a relative path inside the archive.
    dest="${STAGING}${src}"
    mkdir -p "$(dirname "$dest")"
  fi
  if cp -p "$src" "$dest" 2>/dev/null; then
    INCLUDED+=("$src")
  else
    SKIPPED+=("$src (cp failed)")
  fi
}

# ── APNs auth key ────────────────────────────────────────────────────────────

APNS_DIR="/root/.appstoreconnect"
APNS_FOUND=0
if [[ -d "$APNS_DIR" ]]; then
  for p8 in "${APNS_DIR}"/AuthKey_*.p8; do
    [[ -e "$p8" ]] || continue
    stage_file "$p8"
    APNS_FOUND=1
  done
fi
if [[ "$APNS_FOUND" -eq 0 ]]; then
  SKIPPED+=("/root/.appstoreconnect/AuthKey_*.p8 (not found — check GH secrets APNS_KEY_ID / APNS_TEAM_ID / APNS_KEY)")
fi

# ── systemd unit (contains pinned CONDUIT_TOKEN) ─────────────────────────────

UNIT_PATH="/etc/systemd/system/conduit-broker.service"
if [[ -f "$UNIT_PATH" ]]; then
  stage_file "$UNIT_PATH"
else
  SKIPPED+=("$UNIT_PATH (not found)")
fi

# ── agent credentials ─────────────────────────────────────────────────────────

# ~/.claude* — files directly under HOME named .claude or .claude.json etc.
for f in "${HOME}"/.claude*; do
  [[ -e "$f" ]] || continue
  if [[ -f "$f" ]]; then
    stage_file "$f" "home-creds"
  elif [[ -d "$f" ]]; then
    # Recursively copy the directory.
    dest_dir="${STAGING}/home-creds/$(basename "$f")"
    if cp -rp "$f" "$dest_dir" 2>/dev/null; then
      INCLUDED+=("$f/")
    else
      SKIPPED+=("$f/ (cp failed)")
    fi
  fi
done

# ~/.codex
if [[ -d "${HOME}/.codex" ]]; then
  dest_dir="${STAGING}/home-creds/.codex"
  if cp -rp "${HOME}/.codex" "$dest_dir" 2>/dev/null; then
    INCLUDED+=("${HOME}/.codex/")
  else
    SKIPPED+=("${HOME}/.codex/ (cp failed)")
  fi
elif [[ -f "${HOME}/.codex" ]]; then
  stage_file "${HOME}/.codex" "home-creds"
else
  SKIPPED+=("${HOME}/.codex (not found)")
fi

# ~/.gemini
if [[ -d "${HOME}/.gemini" ]]; then
  dest_dir="${STAGING}/home-creds/.gemini"
  if cp -rp "${HOME}/.gemini" "$dest_dir" 2>/dev/null; then
    INCLUDED+=("${HOME}/.gemini/")
  else
    SKIPPED+=("${HOME}/.gemini/ (cp failed)")
  fi
elif [[ -f "${HOME}/.gemini" ]]; then
  stage_file "${HOME}/.gemini" "home-creds"
else
  SKIPPED+=("${HOME}/.gemini (not found)")
fi

# ~/.config/sentry/auth-token
SENTRY_TOKEN="${HOME}/.config/sentry/auth-token"
if [[ -f "$SENTRY_TOKEN" ]]; then
  mkdir -p "${STAGING}/home-creds/.config/sentry"
  if cp -p "$SENTRY_TOKEN" "${STAGING}/home-creds/.config/sentry/auth-token" 2>/dev/null; then
    INCLUDED+=("$SENTRY_TOKEN")
  else
    SKIPPED+=("$SENTRY_TOKEN (cp failed)")
  fi
else
  SKIPPED+=("$SENTRY_TOKEN (not found)")
fi

# ~/.cloudflare-token
CF_TOKEN="${HOME}/.cloudflare-token"
if [[ -f "$CF_TOKEN" ]]; then
  stage_file "$CF_TOKEN" "home-creds"
else
  SKIPPED+=("$CF_TOKEN (not found)")
fi

# ── manifest ──────────────────────────────────────────────────────────────────

MANIFEST="${STAGING}/manifest.txt"
{
  echo "conduit VPS backup"
  echo "Created: $(date -u)"
  echo "Host:    $(hostname -f 2>/dev/null || hostname)"
  echo
  echo "=== INCLUDED ==="
  for item in "${INCLUDED[@]+"${INCLUDED[@]}"}"; do echo "  $item"; done
  echo
  echo "=== SKIPPED ==="
  for item in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "  $item"; done
  echo
  cat <<'RESTORE'
=== RESTORE NOTES ===

1. Decrypt the archive on the new box:
     gpg --decrypt conduit-backup-<timestamp>.tar.gz.gpg | tar -xz

2. APNs key (.p8)
   Place the key back at /root/.appstoreconnect/AuthKey_<KEY_ID>.p8
   (create the directory first: mkdir -p /root/.appstoreconnect).
   The Key ID and Team ID are also stored as GH secrets APNS_KEY_ID /
   APNS_TEAM_ID — but the raw key is ONLY here; GitHub does not expose it.

3. systemd unit (conduit-broker.service)
   Copy to /etc/systemd/system/conduit-broker.service, then:
     systemctl daemon-reload
     systemctl enable --now conduit-broker
   CRITICAL: the unit contains the pinned CONDUIT_TOKEN in its
   Environment= line.  Using the SAME token means paired devices
   reconnect automatically without re-pairing.  Changing the token
   forces both devices to re-pair.

4. Agent credentials (~/.claude* / ~/.codex / ~/.gemini)
   Restore files from home-creds/ back to $HOME.  Log in to each agent
   CLI to verify the restored credentials are accepted.

5. Sentry auth token (~/.config/sentry/auth-token)
   Restore from home-creds/.config/sentry/auth-token.

6. Cloudflare token (~/.cloudflare-token)
   Restore from home-creds/.cloudflare-token.

See docs/BACKUP-RECOVERY.md for the full runbook.
RESTORE
} >"$MANIFEST"

# ── pack and encrypt ──────────────────────────────────────────────────────────

echo "Staging complete.  Creating encrypted archive..."
echo "(You will be prompted twice for the backup passphrase.)"
echo

# tar to stdout → gpg symmetric → output file.
# We explicitly do NOT use --batch so gpg prompts interactively.
# The passphrase never touches disk or shell history.
tar -czf - -C "$STAGING" . \
  | gpg --symmetric --cipher-algo AES256 --output "$OUTPUT"

# Restrict permissions on the output immediately.
chmod 600 "$OUTPUT"

# ── report ────────────────────────────────────────────────────────────────────

echo
echo "Backup written to: $OUTPUT"
echo "Permissions:       $(stat -c '%A' "$OUTPUT")"
echo
echo "Items included (${#INCLUDED[@]}):"
for item in "${INCLUDED[@]+"${INCLUDED[@]}"}"; do echo "  $item"; done
if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
  echo
  echo "Items skipped (${#SKIPPED[@]}) — not an error if paths don't exist on this box:"
  for item in "${SKIPPED[@]}"; do echo "  $item"; done
fi
echo
echo "--- Restore reminder ---"
echo "  gpg --decrypt $OUTPUT | tar -xz"
echo "  Then follow the restore notes in the extracted manifest.txt"
echo "  See: docs/BACKUP-RECOVERY.md"
