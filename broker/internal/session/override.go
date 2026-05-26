package session

import "strings"

// SpawnOverride carries the per-session reasoning-effort / model overrides
// supplied at session creation (the "fork onto a different model / effort"
// path). Both fields are optional; the zero value means "use the adapter's
// defaults unchanged", which keeps the normal (non-fork) start path
// byte-for-byte identical to before.
//
// The override only affects the session it was created with — a fork is a
// brand-new session, so this never mutates the original.
type SpawnOverride struct {
	// ReasoningEffort is one of the labels the agent supports (claude:
	// low/medium/high; codex: low/medium/high). Empty = no override.
	ReasoningEffort string
	// Model is a model alias or full name passed to the agent's --model
	// flag (e.g. "opus", "sonnet", "claude-sonnet-4-6", "gpt-5-codex").
	// Empty = no override.
	Model string
}

// claudeEfforts are the reasoning-effort levels the claude CLI's --effort
// flag accepts (verified against Claude Code 2.1.x: low/medium/high/xhigh/max).
// We expose the three the apps surface; the broker still validates so an
// unknown value is dropped rather than passed through to confuse the CLI.
var claudeEfforts = map[string]bool{
	"low":    true,
	"medium": true,
	"high":   true,
	"xhigh":  true,
	"max":    true,
}

// codexEfforts are the reasoning-effort levels codex accepts via the
// `-c model_reasoning_effort=<level>` config override.
var codexEfforts = map[string]bool{
	"low":    true,
	"medium": true,
	"high":   true,
}

// IsZero reports whether the override carries nothing (the common
// non-fork start path). Callers use it to skip all override plumbing.
func (o SpawnOverride) IsZero() bool {
	return strings.TrimSpace(o.ReasoningEffort) == "" && strings.TrimSpace(o.Model) == ""
}

// extraArgsFor returns the additional CLI args that apply the override for
// the given assistant. It is appended after the adapter's own args on every
// spawn path (PTY, claude stream-json, codex exec). Unknown / unsupported
// values are silently dropped so a bad override never breaks the spawn —
// the session just falls back to the adapter default for that field.
//
//	claude: --effort <level>   --model <model>
//	codex:  -c model_reasoning_effort="<level>"   --model <model>
//
// Returns nil for an empty override or an unrecognized assistant.
func (o SpawnOverride) extraArgsFor(assistant string) []string {
	effort := strings.TrimSpace(o.ReasoningEffort)
	model := strings.TrimSpace(o.Model)
	if effort == "" && model == "" {
		return nil
	}
	var args []string
	switch assistant {
	case "claude":
		if effort != "" && claudeEfforts[effort] {
			args = append(args, "--effort", effort)
		}
		if model != "" {
			args = append(args, "--model", model)
		}
	case "codex":
		if effort != "" && codexEfforts[effort] {
			args = append(args, "-c", "model_reasoning_effort="+effort)
		}
		if model != "" {
			args = append(args, "--model", model)
		}
	}
	return args
}

// effectiveEffort returns the reasoning-effort label that should be
// surfaced on the status frame for this session: the validated override
// when present, otherwise the adapter default ("" → ws falls back to
// "medium"). Mirrors the validation in extraArgsFor so the pill never
// shows an effort the agent didn't actually get.
func (o SpawnOverride) effectiveEffort(assistant, adapterDefault string) string {
	effort := strings.TrimSpace(o.ReasoningEffort)
	if effort == "" {
		return adapterDefault
	}
	switch assistant {
	case "claude":
		if claudeEfforts[effort] {
			return effort
		}
	case "codex":
		if codexEfforts[effort] {
			return effort
		}
	}
	return adapterDefault
}
