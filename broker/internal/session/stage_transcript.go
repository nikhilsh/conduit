package session

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// resumeExcerptN is the number of prior-transcript entries seeded into the
// new session's conversation.jsonl when a Found Session is resumed. Small
// enough to render quickly; large enough to show meaningful context.
const resumeExcerptN = 10

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

// stageClaudeTranscript copies <realHome>/.claude/projects/<slug>/<id>.jsonl
// into <agentHome>/.claude/projects/<slug>/<id>.jsonl, preserving the slug
// directory name so the claude CLI's project-local resolution still matches.
func stageClaudeTranscript(agentHome, realHome, sessionID string) {
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
		// Found the transcript. Mirror to agent-home under the same slug.
		dst := filepath.Join(agentHome, ".claude", "projects", slugEntry.Name(), sessionID+".jsonl")
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
		dst := filepath.Join(agentHome, ".codex", "sessions", rel)
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

// seedResumeExcerpt seeds the new session's conversation.jsonl with a short
// excerpt of the prior external transcript so the Chat tab opens showing recent
// context rather than appearing empty after a Found-Session resume.
//
// It reads the full prior transcript via ExternalTranscript then delegates to
// seedResumeExcerptFromEntries. Best-effort: any error is logged; the session
// continues normally with an empty chat history.
func seedResumeExcerpt(convLogPath, agent, externalID string) {
	if convLogPath == "" || agent == "" || externalID == "" {
		return
	}

	// Fetch the full prior transcript from disk.
	all, err := ExternalTranscript(agent, externalID)
	if err != nil || len(all) == 0 {
		if err != nil {
			log.Printf("found-sessions: seedResumeExcerpt: ExternalTranscript(%s,%s): %v (skipping excerpt seed)", agent, externalID, err)
		} else {
			log.Printf("found-sessions: seedResumeExcerpt: ExternalTranscript(%s,%s) returned empty transcript (skipping excerpt seed)", agent, externalID)
		}
		return
	}

	seedResumeExcerptFromEntries(convLogPath, all, agent)
}

// seedResumeExcerptFromEntries is the testable core of seedResumeExcerpt.
// It takes the already-fetched full transcript (all) and writes up to
// resumeExcerptN of its tail entries plus a trailing system note into
// convLogPath.
//
// Idempotency: if convLogPath already has content (broker restarted and
// re-ran newSession), the seed is skipped — checked by a non-zero file size.
//
// It appends two things (in order):
//  1. The last resumeExcerptN entries (oldest → newest within the excerpt),
//     preserving their original roles and timestamps.
//  2. A trailing "system" entry noting the total turn count and that the
//     full history is loaded in the agent's memory.
func seedResumeExcerptFromEntries(convLogPath string, all []ConvEntry, agent string) {
	if convLogPath == "" || len(all) == 0 {
		return
	}

	// Idempotency guard: skip if conversation.jsonl is already non-empty.
	if info, err := os.Stat(convLogPath); err == nil && info.Size() > 0 {
		log.Printf("found-sessions: seedResumeExcerpt: conversation.jsonl already has content at %s (skipping)", convLogPath)
		return
	}

	totalTurns := len(all)

	// Take the last resumeExcerptN entries (oldest-first within the excerpt).
	excerpt := all
	if len(excerpt) > resumeExcerptN {
		excerpt = excerpt[len(excerpt)-resumeExcerptN:]
	}

	// Ensure the session dir exists (it's created by prepareFilesystem before
	// we reach this point, but be defensive in case tests call us earlier).
	if mkErr := os.MkdirAll(filepath.Dir(convLogPath), 0o700); mkErr != nil {
		log.Printf("found-sessions: seedResumeExcerpt: mkdir %s: %v (skipping)", filepath.Dir(convLogPath), mkErr)
		return
	}

	// Open the log file for append (creates if absent).
	f, openErr := os.OpenFile(convLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if openErr != nil {
		log.Printf("found-sessions: seedResumeExcerpt: open %s: %v (skipping)", convLogPath, openErr)
		return
	}
	defer f.Close()

	// Write each excerpt entry as a JSONL line.
	writeEntry := func(e ConvEntry) error {
		b, merr := json.Marshal(e)
		if merr != nil {
			return merr
		}
		if _, werr := fmt.Fprintf(f, "%s\n", b); werr != nil {
			return werr
		}
		return nil
	}

	for _, e := range excerpt {
		if werr := writeEntry(e); werr != nil {
			log.Printf("found-sessions: seedResumeExcerpt: write entry: %v (partial seed)", werr)
			return
		}
	}

	// Append the trailing system note.
	note := fmt.Sprintf(
		"Resumed from a session you started in your terminal — %d earlier turns. The full history is loaded in %s's memory; the messages above are the most recent excerpt.",
		totalTurns, agent,
	)
	systemEntry := ConvEntry{
		Role:    "system",
		Content: note,
		Ts:      time.Now().UTC().Format(time.RFC3339Nano),
	}
	if werr := writeEntry(systemEntry); werr != nil {
		log.Printf("found-sessions: seedResumeExcerpt: write system note: %v", werr)
		return
	}

	log.Printf("found-sessions: seedResumeExcerpt: seeded %d-entry excerpt + system note into %s (totalTurns=%d)", len(excerpt), convLogPath, totalTurns)
}
