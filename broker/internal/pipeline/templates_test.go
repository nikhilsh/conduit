package pipeline

import (
	"os"
	"path/filepath"
	"testing"
)

// TestTemplateSaveListDelete exercises the full save → list → delete round-trip.
func TestTemplateSaveListDelete(t *testing.T) {
	dir := t.TempDir()

	// List on an empty root returns nil, no error.
	templates, err := ListTemplates(dir)
	if err != nil {
		t.Fatalf("ListTemplates (empty): %v", err)
	}
	if len(templates) != 0 {
		t.Fatalf("expected 0 templates; got %d", len(templates))
	}

	// Save a template.
	tmpl := &Template{
		ID:    NewTemplateID(),
		Title: "Research + Build",
		Task:  "Implement a rate limiter",
		Steps: []TemplateStep{
			{AgentType: "claude", Role: "researcher", PromptTemplate: "Research: {{task}}", InputFromPrev: InputNone, GateAfter: false},
			{AgentType: "claude", Role: "engineer", PromptTemplate: "Implement: {{prev}}", InputFromPrev: InputMemoryOutput, GateAfter: true},
		},
	}
	if err := SaveTemplate(dir, tmpl); err != nil {
		t.Fatalf("SaveTemplate: %v", err)
	}

	// Verify the file exists with the right shape.
	path := filepath.Join(dir, "pipeline-templates", tmpl.ID+".json")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("template file missing: %v", err)
	}

	// List returns the saved template.
	templates, err = ListTemplates(dir)
	if err != nil {
		t.Fatalf("ListTemplates: %v", err)
	}
	if len(templates) != 1 {
		t.Fatalf("expected 1 template; got %d", len(templates))
	}
	got := templates[0]
	if got.ID != tmpl.ID {
		t.Errorf("ID=%q, want %q", got.ID, tmpl.ID)
	}
	if got.Title != tmpl.Title {
		t.Errorf("Title=%q, want %q", got.Title, tmpl.Title)
	}
	if got.Task != tmpl.Task {
		t.Errorf("Task=%q, want %q", got.Task, tmpl.Task)
	}
	if len(got.Steps) != 2 {
		t.Fatalf("Steps len=%d, want 2", len(got.Steps))
	}
	if got.Steps[0].Role != "researcher" {
		t.Errorf("step 0 role=%q, want researcher", got.Steps[0].Role)
	}
	if got.Steps[1].GateAfter != true {
		t.Error("step 1 GateAfter should be true")
	}
	if got.Steps[1].InputFromPrev != InputMemoryOutput {
		t.Errorf("step 1 InputFromPrev=%q, want memory+output", got.Steps[1].InputFromPrev)
	}

	// LoadTemplate round-trip.
	loaded, err := LoadTemplate(dir, tmpl.ID)
	if err != nil {
		t.Fatalf("LoadTemplate: %v", err)
	}
	if loaded.Title != tmpl.Title {
		t.Errorf("loaded Title=%q", loaded.Title)
	}

	// Delete.
	if err := DeleteTemplate(dir, tmpl.ID); err != nil {
		t.Fatalf("DeleteTemplate: %v", err)
	}

	// File must be gone.
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("template file still exists after delete: %v", err)
	}

	// List must be empty again.
	templates, err = ListTemplates(dir)
	if err != nil {
		t.Fatalf("ListTemplates after delete: %v", err)
	}
	if len(templates) != 0 {
		t.Fatalf("expected 0 templates after delete; got %d", len(templates))
	}
}

// TestDeleteTemplateMissingReturnsError verifies that deleting a nonexistent
// template returns a "not found" error (not a nil / silent no-op).
func TestDeleteTemplateMissingReturnsError(t *testing.T) {
	dir := t.TempDir()
	err := DeleteTemplate(dir, "p_nonexist")
	if err == nil {
		t.Fatal("expected error for missing template; got nil")
	}
	if !isNotFoundMsg(err.Error()) {
		t.Errorf("error does not mention 'not found': %v", err)
	}
}

// TestLoadTemplateMissingReturnsError verifies that loading a nonexistent
// template returns a "not found" error.
func TestLoadTemplateMissingReturnsError(t *testing.T) {
	dir := t.TempDir()
	_, err := LoadTemplate(dir, "p_missing")
	if err == nil {
		t.Fatal("expected error for missing template; got nil")
	}
	if !isNotFoundMsg(err.Error()) {
		t.Errorf("error does not mention 'not found': %v", err)
	}
}

// isNotFoundMsg checks if an error message contains "not found".
func isNotFoundMsg(msg string) bool {
	for _, s := range []string{"not found", "not_found", "no such file"} {
		if len(msg) >= len(s) {
			for i := 0; i <= len(msg)-len(s); i++ {
				if msg[i:i+len(s)] == s {
					return true
				}
			}
		}
	}
	return false
}

// TestTemplateSaveIsAtomic verifies the atomic write (tmp→rename) by checking
// that a second Save overwrites the first without leaving a .tmp file behind.
func TestTemplateSaveIsAtomic(t *testing.T) {
	dir := t.TempDir()
	tmpl := &Template{
		ID:    NewTemplateID(),
		Title: "v1",
		Steps: []TemplateStep{{AgentType: "claude"}},
	}
	if err := SaveTemplate(dir, tmpl); err != nil {
		t.Fatalf("SaveTemplate v1: %v", err)
	}
	tmpl.Title = "v2"
	if err := SaveTemplate(dir, tmpl); err != nil {
		t.Fatalf("SaveTemplate v2: %v", err)
	}

	loaded, err := LoadTemplate(dir, tmpl.ID)
	if err != nil {
		t.Fatalf("LoadTemplate: %v", err)
	}
	if loaded.Title != "v2" {
		t.Errorf("Title=%q, want v2", loaded.Title)
	}

	// No leftover .tmp file.
	tmpPath := filepath.Join(dir, "pipeline-templates", tmpl.ID+".json.tmp")
	if _, err := os.Stat(tmpPath); !os.IsNotExist(err) {
		t.Errorf(".tmp file left behind: %v", err)
	}
}
