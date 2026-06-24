package session

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// stageExternalTranscript copies the external agent's conversation file from
// the user's REAL home into the per-session agent-home so that the agent
// launched with --resume <externalID> (claude) or exec resume <externalID>
// (codex) actually finds the conversation instead of exiting 1 with "No
// conversation found".
//
// Root cause: the broker isolates each session's HOME to prevent concurrent
// OAuth token-rotation races.  An external session's transcript lives in the
// user's real home (~/.claude/projects/<slug>/<id>.jsonl or
// ~/.codex/sessions/YYYY/MM/DD/<rollout>.jsonl), not in the isolated
// agent-home, so a plain --resume fails.
//
// Best-effort + idempotent: if the file is already present in agent-home,
// it is skipped.  A failure is logged but never blocks the spawn — the
// agent will start amnesiac (same behaviour as before this fix) rather than
// refusing to run.
//
// Parameters:
//
//	agentHome  — per-session ephemeral $HOME (e.g. .conduit/sessions/<id>/agent-home)
//	realHome   — the broker's actual $HOME (from hostHomeDir())
//	agent      — "claude" | "codex"
//	externalID — the claude session UUID or codex thread ID
func stageExternalTranscript(agentHome, realHome, agent, externalID string) {
	if agentHome == "" || realHome == "" || externalID == "" {
		return
	}
	switch agent {
	case "claude":
		stageClaudeTranscript(agentHome, realHome, externalID)
	case "codex":
		stageCodexTranscript(agentHome, realHome, externalID)
	default:
		log.Printf("found-sessions: stageExternalTranscript: unknown agent %q (skipping)", agent)
	}
}

// stageExternalTranscriptInto is the CONDUIT_SHARED_AGENT_CREDS variant of
// stageExternalTranscript: under the flag the agent reads its transcripts
// (projects/ for claude, sessions/ for codex) from the SHARED canonical
// config dir the relocation env var points at, not from the per-session
// agent-home. `dirs` is the provider->canonical-dir map from sharedCredEnv
// (keys "anthropic" / "openai"). When a provider's canonical dir is absent
// it falls back to the per-session agent-home layout (defensive; should not
// happen under the flag). Under Option A the canonical dir IS the host
// config dir, so staging is an idempotent no-op (the transcript is already
// there). See doc §3.6.
func stageExternalTranscriptInto(dirs map[string]string, agentHome, realHome, agent, externalID string) {
	if realHome == "" || externalID == "" {
		return
	}
	switch agent {
	case "claude":
		dst := filepath.Join(agentHome, ".claude")
		if d := dirs["anthropic"]; d != "" {
			dst = d
		}
		stageClaudeTranscriptInto(dst, realHome, externalID)
	case "codex":
		dst := filepath.Join(agentHome, ".codex")
		if d := dirs["openai"]; d != "" {
			dst = d
		}
		stageCodexTranscriptInto(dst, realHome, externalID)
	default:
		log.Printf("found-sessions: stageExternalTranscriptInto: unknown agent %q (skipping)", agent)
	}
}

// stageClaudeTranscript copies <realHome>/.claude/projects/<slug>/<id>.jsonl
// into <agentHome>/.claude/projects/<slug>/<id>.jsonl, preserving the slug
// directory name so the claude CLI's project-local resolution still matches.
func stageClaudeTranscript(agentHome, realHome, sessionID string) {
	stageClaudeTranscriptInto(filepath.Join(agentHome, ".claude"), realHome, sessionID)
}

// stageClaudeTranscriptInto copies the claude transcript into
// <destConfigDir>/projects/<slug>/<id>.jsonl. destConfigDir is the claude
// config dir (per-session `<agentHome>/.claude` on the flag-off path, or the
// shared CLAUDE_CONFIG_DIR canonical dir on the flag-on path).
func stageClaudeTranscriptInto(destConfigDir, realHome, sessionID string) {
	srcBase := filepath.Join(realHome, ".claude", "projects")
	slugDirs, err := os.ReadDir(srcBase)
	if err != nil {
		log.Printf("found-sessions: stage claude transcript: readdir %s: %v", srcBase, err)
		return
	}
	for _, slugEntry := range slugDirs {
		if !slugEntry.IsDir() {
			continue
		}
		src := filepath.Join(srcBase, slugEntry.Name(), sessionID+".jsonl")
		if _, err := os.Stat(src); err != nil {
			continue
		}
		// Found the transcript. Mirror to the dest config dir under the same slug.
		dst := filepath.Join(destConfigDir, "projects", slugEntry.Name(), sessionID+".jsonl")
		if _, err := os.Stat(dst); err == nil {
			// Already staged (idempotent).
			log.Printf("found-sessions: claude transcript already staged at %s (skipping)", dst)
			return
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			log.Printf("found-sessions: stage claude transcript: mkdir %s: %v", filepath.Dir(dst), err)
			return
		}
		if err := stageCopyFile(src, dst, 0o600); err != nil {
			log.Printf("found-sessions: stage claude transcript: copy %s → %s: %v", src, dst, err)
			return
		}
		log.Printf("found-sessions: staged claude transcript %s → %s", src, dst)
		return
	}
	// No match found — transcript may have been cleaned up or the ID is wrong.
	log.Printf("found-sessions: claude transcript for %s not found under %s (agent will start fresh)", sessionID, srcBase)
}

// stageCodexTranscript copies <realHome>/.codex/sessions/YYYY/MM/DD/<rollout>.jsonl
// (the file whose name contains externalID) into the corresponding path under
// <agentHome>/.codex/sessions/…, preserving the date-path hierarchy.
func stageCodexTranscript(agentHome, realHome, sessionID string) {
	stageCodexTranscriptInto(filepath.Join(agentHome, ".codex"), realHome, sessionID)
}

// stageCodexTranscriptInto copies the codex rollout into
// <destConfigDir>/sessions/<rel>. destConfigDir is the codex CODEX_HOME dir
// (per-session `<agentHome>/.codex` on the flag-off path, or the shared
// CODEX_HOME canonical dir on the flag-on path).
func stageCodexTranscriptInto(destConfigDir, realHome, sessionID string) {
	srcBase := filepath.Join(realHome, ".codex", "sessions")
	found := false
	// Walk YYYY/MM/DD structure.
	err := filepath.WalkDir(srcBase, func(path string, d os.DirEntry, werr error) error {
		if werr != nil || d.IsDir() {
			return nil // skip unreadable dirs
		}
		if !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		if !strings.Contains(filepath.Base(path), sessionID) {
			return nil
		}
		// path is the source rollout file.
		// Derive the relative date path (e.g. YYYY/MM/DD/rollout-xxx.jsonl).
		rel, err := filepath.Rel(srcBase, path)
		if err != nil {
			return nil
		}
		dst := filepath.Join(destConfigDir, "sessions", rel)
		if _, serr := os.Stat(dst); serr == nil {
			log.Printf("found-sessions: codex transcript already staged at %s (skipping)", dst)
			found = true
			return filepath.SkipAll
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			log.Printf("found-sessions: stage codex transcript: mkdir %s: %v", filepath.Dir(dst), err)
			found = true
			return filepath.SkipAll
		}
		if err := stageCopyFile(path, dst, 0o600); err != nil {
			log.Printf("found-sessions: stage codex transcript: copy %s → %s: %v", path, dst, err)
			found = true
			return filepath.SkipAll
		}
		log.Printf("found-sessions: staged codex transcript %s → %s", path, dst)
		found = true
		return filepath.SkipAll
	})
	if err != nil {
		log.Printf("found-sessions: stage codex transcript: walk %s: %v", srcBase, err)
	}
	if !found {
		log.Printf("found-sessions: codex transcript for %s not found under %s (agent will start fresh)", sessionID, srcBase)
	}
}

// stageCopyFile reads src and writes its contents to dst with the given mode.
// Uses atomicWriteFileMode so a partial write never leaves a half-written file.
func stageCopyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	return atomicWriteFileMode(dst, data, mode)
}
