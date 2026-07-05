package pipeline

// StepConfig carries the optional per-block agent configuration shared by
// Step and TemplateStep. It is embedded (not duplicated) in both types so
// the two cannot drift out of lockstep — a field added here appears on
// both without a second definition.
//
// All fields are optional; the zero value ("") means "use the adapter
// default", which keeps a step that sets none of these byte-identical to
// a pipeline defined before this type existed.
type StepConfig struct {
	// Model is a model alias or full name passed to the agent's --model
	// flag (e.g. "opus", "sonnet", "gpt-5-codex"). "" = adapter default.
	Model string `json:"model,omitempty"`
	// ReasoningEffort is one of the labels the agent supports (e.g. claude/
	// codex: low/medium/high). "" = adapter default.
	ReasoningEffort string `json:"reasoning_effort,omitempty"`
	// PermissionMode selects the agent's permission posture: "" / "auto" =
	// the adapter default (today's full-auto bypass, unchanged); "plan" =
	// read-only planning.
	PermissionMode string `json:"permission_mode,omitempty"`
	// Instructions, when non-empty, is prepended to the rendered prompt as
	// a <block-instructions> preamble before it becomes the initial user
	// turn (see spawnStepOpts). "" = no preamble, byte-identical to a step
	// defined before this field existed.
	Instructions string `json:"instructions,omitempty"`
}
