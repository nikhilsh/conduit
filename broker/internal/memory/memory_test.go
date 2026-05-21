package memory

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInitCheckpointRenderAndShow(t *testing.T) {
	root := t.TempDir()
	if err := Init(root); err != nil {
		t.Fatalf("Init: %v", err)
	}
	now := time.Date(2026, 5, 17, 12, 0, 0, 0, time.UTC)
	doc, err := Checkpoint(root, CheckpointOptions{
		SessionData: SessionData{
			SessionID:      "session-123",
			WorktreePath:   "/tmp/work",
			Branch:         "agent/codex-005-memory-checkpoint",
			TaskID:         "005",
			CurrentAgent:   "codex",
			CreatedAt:      now,
			CheckpointAt:   now,
			TaskBriefPath:  ".swe-kitty/tasks/005-memory-checkpoint.md",
			TaskSummary:    "Implement the memory package.",
			LastCompleted:  "Scaffolded the session memory file",
			CurrentlyDoing: "Updating the validator",
			NextStep:       "Wire the CLI surface",
			ScrollbackTail: "go test ./...\n",
		},
		Reason: "periodic checkpoint",
	})
	if err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	if err := ValidateDocument(doc); err != nil {
		t.Fatalf("ValidateDocument(checkpoint): %v", err)
	}

	rendered, err := Render(root, "session-123")
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if !strings.Contains(rendered, "periodic checkpoint") {
		t.Fatalf("rendered checkpoint missing reason: %s", rendered)
	}

	plaintext, err := Show(root, "session-123")
	if err != nil {
		t.Fatalf("Show: %v", err)
	}
	if !strings.Contains(plaintext, "Implement the memory package.") {
		t.Fatalf("Show output missing task summary: %q", plaintext)
	}
}

func TestValidateRejectsDuplicateDecisionIDs(t *testing.T) {
	doc := strings.Replace(defaultProjectHTML, "<ol></ol>", `<ol><li data-id="d-001">one</li><li data-id="d-001">two</li></ol>`, 1)
	err := ValidateDocument(doc)
	if err == nil || !strings.Contains(err.Error(), "duplicate decision data-id") {
		t.Fatalf("expected duplicate data-id error, got %v", err)
	}
}

func TestHandoffMergesOutgoingSection(t *testing.T) {
	root := t.TempDir()
	if err := Init(root); err != nil {
		t.Fatalf("Init: %v", err)
	}
	now := time.Date(2026, 5, 17, 12, 0, 0, 0, time.UTC)
	_, err := Checkpoint(root, CheckpointOptions{
		SessionData: SessionData{
			SessionID:     "swap-me",
			WorktreePath:  "/tmp/work",
			Branch:        "agent/claude-005-memory-checkpoint",
			TaskID:        "005",
			CurrentAgent:  "claude",
			CreatedAt:     now,
			CheckpointAt:  now,
			TaskBriefPath: ".swe-kitty/tasks/005-memory-checkpoint.md",
			TaskSummary:   "Prepare swap",
		},
	})
	if err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	handoffDoc := strings.Replace(defaultSessionTemplateHTML, "{{SESSION_UUID}}", "swap-me", 1)
	handoffDoc = strings.Replace(handoffDoc, "{{WORKTREE_PATH}}", "/tmp/work", 1)
	handoffDoc = strings.Replace(handoffDoc, "{{BRANCH}}", "agent/claude-005-memory-checkpoint", 1)
	handoffDoc = strings.Replace(handoffDoc, "{{TASK_ID}}", "005", 1)
	handoffDoc = strings.Replace(handoffDoc, "{{AGENT_NAME}}", "claude", 1)
	handoffDoc = strings.ReplaceAll(handoffDoc, "{{CREATED_ISO}}", now.Format(time.RFC3339))
	handoffDoc = strings.ReplaceAll(handoffDoc, "{{CHECKPOINT_ISO}}", now.Format(time.RFC3339))
	handoffDoc = strings.Replace(handoffDoc, "{{TASK_BRIEF_PATH}}", ".swe-kitty/tasks/005-memory-checkpoint.md", 1)
	handoffDoc = strings.Replace(handoffDoc, "{{TASK_SUMMARY}}", "Prepare swap", 1)
	handoffDoc = replaceSection(handoffDoc, "handoff", buildHandoffSection("claude", "codex", "swap requested", "<p>Wire the CLI next.</p>", false))
	path := filepath.Join(root, ".swe-kitty", "HANDOFF-OUT.html")
	if err := atomicWrite(path, []byte(handoffDoc)); err != nil {
		t.Fatalf("atomicWrite(handoff): %v", err)
	}

	merged, err := Handoff(root, HandoffOptions{
		SessionID: "swap-me",
		From:      "claude",
		To:        "codex",
	})
	if err != nil {
		t.Fatalf("Handoff: %v", err)
	}
	if strings.Contains(merged, `data-section="handoff" hidden`) {
		t.Fatalf("handoff section still hidden: %s", merged)
	}
	if !strings.Contains(merged, "Wire the CLI next.") {
		t.Fatalf("handoff body missing in merged doc: %s", merged)
	}
}

func TestPromoteCopiesDecisionIntoProjectMemory(t *testing.T) {
	root := t.TempDir()
	if err := Init(root); err != nil {
		t.Fatalf("Init: %v", err)
	}
	now := time.Date(2026, 5, 17, 12, 0, 0, 0, time.UTC)
	doc, err := Checkpoint(root, CheckpointOptions{
		SessionData: SessionData{
			SessionID:     "session-123",
			WorktreePath:  "/tmp/work",
			Branch:        "agent/codex-005-memory-checkpoint",
			TaskID:        "005",
			CurrentAgent:  "codex",
			CreatedAt:     now,
			CheckpointAt:  now,
			TaskBriefPath: ".swe-kitty/tasks/005-memory-checkpoint.md",
			TaskSummary:   "Implement promote",
		},
	})
	if err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	doc, err = appendListItem(doc, "decisions", `<li data-id="d-001">Prefer atomic writes.</li>`)
	if err != nil {
		t.Fatalf("appendListItem: %v", err)
	}
	if err := atomicWrite(DefaultPaths(root).sessionFile("session-123"), []byte(doc)); err != nil {
		t.Fatalf("atomicWrite(session): %v", err)
	}

	result, err := Promote(root, "session-123", "d-001", now)
	if err != nil {
		t.Fatalf("Promote: %v", err)
	}
	if result.PromotedDecision != "d-001" {
		t.Fatalf("expected promoted id d-001, got %s", result.PromotedDecision)
	}
	projectDoc, err := os.ReadFile(DefaultPaths(root).ProjectFile)
	if err != nil {
		t.Fatalf("ReadFile(project): %v", err)
	}
	if !strings.Contains(string(projectDoc), "Prefer atomic writes.") {
		t.Fatalf("project memory missing promoted decision: %s", string(projectDoc))
	}
	if !strings.Contains(string(projectDoc), "session-123") {
		t.Fatalf("project memory missing session provenance: %s", string(projectDoc))
	}
}
