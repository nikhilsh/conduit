package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// cwdToClaudeSlug converts an absolute workspace path to the slug Claude uses
// as its per-project directory name under ~/.claude/projects/.
//
// Claude's rule: remove the leading '/', then replace every '/' with '-'.
// e.g. "/root/developer/projects/conduit" → "-root-developer-projects-conduit"
//
// Cross-reference: claudeSlugToCWD (external_discovery.go:419-428) is the
// inverse. Both functions MUST agree on the transformation — if you update one,
// update the other. The slug round-trip is tested in agent_memory_test.go.
//
// Note: the mapping is not injective (path components containing '-' are
// indistinguishable from path separators), but it matches exactly what Claude
// Code itself computes, so the broker's stable store and the CLI's own slug
// always agree for the same workspace path.
func cwdToClaudeSlug(path string) string {
	if path == "" || path == "/" {
		return path
	}
	// Strip leading slash, then replace remaining '/' with '-' and prepend '-'.
	trimmed := strings.TrimPrefix(path, "/")
	return "-" + strings.ReplaceAll(trimmed, "/", "-")
}

// linkPersistentAgentState wires up a stable, non-GC'd per-project store for
// Claude's agent memory (the projects/ subtree) by placing a symlink inside
// the per-session ephemeral HOME so that every session for the same workspace
// shares one persistent memory directory.
//
// Layout:
//
//	<conduitRoot>/agent-state/<provider>/<slug>/projects/  ← stable store
//	<ephemeralHome>/.claude/projects                       → symlink to above
//
// Only the projects CHILD of .claude is redirected. The credential file
// .claude/.credentials.json stays a real ephemeral file in agent-home/.claude/
// — this preserves the OAuth refresh-token isolation invariant exactly. See the
// large comment at manager.go:446-463 for why credentials must be per-session.
//
// Best-effort: any error is logged and the caller falls back to today's
// ephemeral-only behaviour. This function NEVER blocks a session spawn.
//
// Not called from the spawn path today: every session's CLAUDE_CONFIG_DIR
// already points at a stable, shared location (the operator's ~/.claude or
// <conduitRoot>/agent-cred/.claude — docs/PLAN-AGENT-CREDENTIAL-LINEAGE.md),
// so projects/ already persists there natively and redirecting it again
// would interfere. Retained (and directly unit-tested below) as the
// documented mechanism, in case a future provider needs a per-project
// symlink into a stable store outside the shared canonical config dir.
func linkPersistentAgentState(ephemeralHome, conduitRoot, provider, workspaceDir string) error {
	if ephemeralHome == "" || conduitRoot == "" || workspaceDir == "" {
		return nil
	}

	// Only support claude (anthropic) in this release.
	//
	// TODO(codex memory persistence): live-inspected `~/.codex` on the box
	// (codex-cli 0.143.0). Findings:
	//   - `.codex/memories/` DOES exist as a directory decoupled from
	//     `auth.json` (a sibling file, not nested under memories/), so a
	//     credential-safe redirect target is plausible file-wise.
	//   - BUT unlike claude's `.claude/projects/<slug>/`, codex's memory is
	//     NOT keyed per project on disk: `memories/` is one flat tree
	//     (MEMORY.md, raw_memories.md, rollout_summaries/, its own internal
	//     git repo) shared across every project the installation has ever
	//     touched. `config.toml`'s `[projects."<path>"]` blocks only carry
	//     `trust_level`, not memory scoping. There's also a top-level
	//     `memories_1.sqlite` (tables: jobs, stage1_outputs) that isn't even
	//     under `memories/`.
	//   - Symlinking a per-`<provider,slug>` `agent-state/openai/<slug>/`
	//     store onto this GLOBAL tree would either (a) silently fragment one
	//     continuous cross-project memory into isolated per-project copies
	//     the CLI never expected, or (b) require sharing ONE global codex
	//     store across all projects — a different grain than the claude
	//     design and a real product-behavior question, not a plumbing one.
	// Given that ambiguity, codex is shipped OUT of v1. Revisit once codex's
	// memory model is confirmed either project-scoped (redirect it like
	// claude) or intentionally global (redirect once, un-keyed, with an
	// explicit owner decision — do NOT invent a scoping the CLI doesn't have).
	// Under no circumstances redirect anything that could pull in auth.json.
	if provider != "anthropic" {
		return nil
	}

	slug := cwdToClaudeSlug(workspaceDir)
	if slug == "" {
		return fmt.Errorf("linkPersistentAgentState: empty slug for workspaceDir %q", workspaceDir)
	}

	// Stable store: <conduitRoot>/agent-state/<provider>/<slug>/projects
	stableProjectsDir := filepath.Join(conduitRoot, "agent-state", provider, slug, "projects")
	if err := os.MkdirAll(stableProjectsDir, 0o700); err != nil {
		return fmt.Errorf("linkPersistentAgentState: mkdir stable store: %w", err)
	}

	// Best-effort one-time migration seed: if the stable store is empty, copy
	// any memory from the most recently touched existing session's agent-home
	// for this slug. This recovers memory that wasn't yet GC'd before the
	// first spawn under the new layout.
	seedPersistentStore(conduitRoot, provider, slug, stableProjectsDir)

	// Prepare .claude parent in the ephemeral home.
	claudeDir := filepath.Join(ephemeralHome, ".claude")
	if err := os.MkdirAll(claudeDir, 0o700); err != nil {
		return fmt.Errorf("linkPersistentAgentState: mkdir .claude in ephemeral: %w", err)
	}

	// Create the symlink: <ephemeralHome>/.claude/projects → stableProjectsDir
	linkPath := filepath.Join(claudeDir, "projects")
	if err := os.Symlink(stableProjectsDir, linkPath); err != nil {
		// EEXIST is expected when .claude already existed (e.g. mirrorHostCredentials
		// ran first and created .claude/projects as a real dir). Remove and retry once.
		if os.IsExist(err) {
			if rmErr := os.RemoveAll(linkPath); rmErr != nil {
				return fmt.Errorf("linkPersistentAgentState: remove existing projects dir: %w", rmErr)
			}
			if err2 := os.Symlink(stableProjectsDir, linkPath); err2 != nil {
				return fmt.Errorf("linkPersistentAgentState: symlink (retry): %w", err2)
			}
		} else {
			return fmt.Errorf("linkPersistentAgentState: symlink: %w", err)
		}
	}

	return nil
}

// seedPersistentStore performs a best-effort one-time migration from the
// most recently touched existing session's agent-home for this slug. It
// runs only when the stable store is empty (no entries) and at most copies
// the first matching session's projects/<slug> content. Never blocks spawn.
func seedPersistentStore(conduitRoot, provider, slug, stableProjectsDir string) {
	// Only seed if the stable store is empty.
	entries, err := os.ReadDir(stableProjectsDir)
	if err != nil || len(entries) > 0 {
		return
	}

	// Walk sessions/<id>/agent-home/.claude/projects/<slug> looking for the
	// most recently modified one. Use only the first match found (ordering is
	// arbitrary but sufficient for a one-time seed).
	sessionsRoot := filepath.Join(conduitRoot, "sessions")
	sessionEntries, err := os.ReadDir(sessionsRoot)
	if err != nil {
		return
	}

	configSubdir := ".claude" // anthropic only (provider == "anthropic" gate above)
	for _, entry := range sessionEntries {
		if !entry.IsDir() {
			continue
		}
		srcProjectsSlug := filepath.Join(sessionsRoot, entry.Name(), "agent-home", configSubdir, "projects", slug)
		info, err := os.Stat(srcProjectsSlug)
		if err != nil || !info.IsDir() {
			continue
		}
		// Found a candidate; copy its contents into the stable store.
		if copyErr := copyDirContents(srcProjectsSlug, stableProjectsDir); copyErr != nil {
			fmt.Fprintf(os.Stderr, "agent-state: seed from session %s: %v (non-fatal)\n", entry.Name(), copyErr)
		}
		return // one migration seed is enough
	}
}

// copyDirContents recursively copies the contents of src into dst.
// dst must already exist. Best-effort: errors on individual entries are
// logged but do not abort the overall copy.
func copyDirContents(src, dst string) error {
	entries, err := os.ReadDir(src)
	if err != nil {
		return fmt.Errorf("readdir %s: %w", src, err)
	}
	for _, e := range entries {
		srcPath := filepath.Join(src, e.Name())
		dstPath := filepath.Join(dst, e.Name())
		if e.IsDir() {
			if mkErr := os.MkdirAll(dstPath, 0o700); mkErr != nil {
				fmt.Fprintf(os.Stderr, "agent-state seed: mkdir %s: %v\n", dstPath, mkErr)
				continue
			}
			if cpErr := copyDirContents(srcPath, dstPath); cpErr != nil {
				fmt.Fprintf(os.Stderr, "agent-state seed: copyDirContents %s: %v\n", srcPath, cpErr)
			}
		} else {
			if cpErr := copyFile(srcPath, dstPath); cpErr != nil {
				fmt.Fprintf(os.Stderr, "agent-state seed: copyFile %s: %v\n", srcPath, cpErr)
			}
		}
	}
	return nil
}

// copyFile copies a single regular file from src to dst, preserving mode.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, info.Mode().Perm())
}
