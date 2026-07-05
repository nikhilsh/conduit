package pipeline

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Template is a reusable pipeline preset. It holds a title, a shared task
// description, and an ordered list of step definitions. IDs have the same
// shape as Pipeline IDs ("p_" + 8 random hex chars) so they are visually
// distinct from ordinary UUIDs and easy to recognise in logs.
//
// Templates are stored under <conduitRoot>/pipeline-templates/<id>.json.
// Creating a pipeline FROM a template is client-side: the app prefills the
// Builder with these fields and POSTs /api/pipeline as normal.
type Template struct {
	ID    string         `json:"id"`
	Title string         `json:"title"`
	Task  string         `json:"task,omitempty"`
	Steps []TemplateStep `json:"steps"`
}

// TemplateStep holds the definition fields of a step (no live-state fields).
type TemplateStep struct {
	AgentType      string        `json:"agent_type"`
	Role           string        `json:"role,omitempty"`
	PromptTemplate string        `json:"prompt_template,omitempty"`
	InputFromPrev  InputFromPrev `json:"input_from_prev"`
	GateAfter      bool          `json:"gate_after"`
	// StepConfig (embedded) — see pipeline.go / stepconfig.go. Embedding the
	// same shared struct as Step is the lockstep guard: a field added there
	// appears here automatically with no separate definition to drift.
	StepConfig
}

// NewTemplateID generates a template ID using the same scheme as NewID.
func NewTemplateID() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return "p_" + hex.EncodeToString(b[:])
}

// templateDir returns the directory that stores all templates.
func templateDir(conduitRoot string) string {
	return filepath.Join(conduitRoot, "pipeline-templates")
}

// templatePath returns the path to a single template's JSON file.
func templatePath(conduitRoot, id string) string {
	return filepath.Join(templateDir(conduitRoot), id+".json")
}

// SaveTemplate persists t to <conduitRoot>/pipeline-templates/<id>.json.
func SaveTemplate(conduitRoot string, t *Template) error {
	dir := templateDir(conduitRoot)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("template %s: mkdir: %w", t.ID, err)
	}
	data, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return fmt.Errorf("template %s: marshal: %w", t.ID, err)
	}
	path := templatePath(conduitRoot, t.ID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("template %s: write: %w", t.ID, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("template %s: rename: %w", t.ID, err)
	}
	return nil
}

// LoadTemplate reads a template from <conduitRoot>/pipeline-templates/<id>.json.
func LoadTemplate(conduitRoot, id string) (*Template, error) {
	if id == "" {
		return nil, fmt.Errorf("template id is required")
	}
	data, err := os.ReadFile(templatePath(conduitRoot, id))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("template %s: not found", id)
		}
		return nil, fmt.Errorf("template %s: read: %w", id, err)
	}
	var t Template
	if err := json.Unmarshal(data, &t); err != nil {
		return nil, fmt.Errorf("template %s: unmarshal: %w", id, err)
	}
	return &t, nil
}

// DeleteTemplate removes <conduitRoot>/pipeline-templates/<id>.json.
// Returns an os.ErrNotExist-wrapped error when the file is missing.
func DeleteTemplate(conduitRoot, id string) error {
	path := templatePath(conduitRoot, id)
	err := os.Remove(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("template %s: not found", id)
		}
		return fmt.Errorf("template %s: delete: %w", id, err)
	}
	return nil
}

// ListTemplates scans <conduitRoot>/pipeline-templates/ and loads all templates.
// Missing or malformed entries are skipped silently.
func ListTemplates(conduitRoot string) ([]*Template, error) {
	dir := templateDir(conduitRoot)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list templates: %w", err)
	}
	var out []*Template
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if filepath.Ext(name) != ".json" {
			continue
		}
		id := name[:len(name)-len(".json")]
		t, err := LoadTemplate(conduitRoot, id)
		if err != nil {
			// Skip corrupt entries.
			continue
		}
		out = append(out, t)
	}
	return out, nil
}
