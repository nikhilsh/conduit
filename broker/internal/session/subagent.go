package session

import (
	"encoding/json"
	"sync"
	"time"
)

// subagentNode is one entry in the per-session subagent roster. All
// fields are populated from system/task_* stream-json frames. Guards via
// the Session.mu that wraps the registry map.
type subagentNode struct {
	TaskID      string    `json:"task_id"`
	Name        string    `json:"name"`        // == subagent_type (display label)
	Description string    `json:"description"` // last description seen
	Status      string    `json:"status"`      // "working" | "done" | "failed"
	LastTool    string    `json:"last_tool"`   // last_tool_name from task_progress; "" if unknown
	Tokens      uint64    `json:"tokens"`      // usage.total_tokens
	ToolUses    uint64    `json:"tool_uses"`   // usage.tool_uses
	DurationMS  uint64    `json:"duration_ms"` // usage.duration_ms
	StartedAt   time.Time `json:"-"`           // broker clock; marshaled separately
	EndedAt     time.Time `json:"-"`           // zero until done/failed; marshaled separately
}

// subagentRegistry is the per-session ordered registry of subagents seen
// this session. Ordering is insertion order (slice preserves spawn order).
// All access must be under the caller's Session.mu.
type subagentRegistry struct {
	order []*subagentNode          // insertion order (newest spawn appended)
	byID  map[string]*subagentNode // fast lookup by task_id
}

func newSubagentRegistry() *subagentRegistry {
	return &subagentRegistry{byID: make(map[string]*subagentNode)}
}

// apply updates (or creates) the node for the task event and returns true
// if any visible state changed (i.e. the caller should re-emit the roster).
// Must be called under Session.mu.
func (r *subagentRegistry) apply(ev subagentTaskEvent, now time.Time) bool {
	node, exists := r.byID[ev.TaskID]
	switch ev.Subtype {
	case "task_started":
		if !exists {
			node = &subagentNode{
				TaskID:    ev.TaskID,
				Name:      ev.SubagentType,
				StartedAt: now,
				Status:    "working",
			}
			if ev.Description != "" {
				node.Description = ev.Description
			}
			r.order = append(r.order, node)
			r.byID[ev.TaskID] = node
			return true
		}
		// Duplicate task_started — no-op.
		return false

	case "task_progress":
		if !exists {
			// Progress before started — create a placeholder so we don't lose data.
			node = &subagentNode{
				TaskID:    ev.TaskID,
				Name:      ev.SubagentType,
				StartedAt: now,
				Status:    "working",
			}
			r.order = append(r.order, node)
			r.byID[ev.TaskID] = node
		}
		if ev.SubagentType != "" {
			node.Name = ev.SubagentType
		}
		if ev.Description != "" {
			node.Description = ev.Description
		}
		if ev.LastToolName != "" {
			node.LastTool = ev.LastToolName
		}
		node.Tokens = ev.Usage.TotalTokens
		node.ToolUses = ev.Usage.ToolUses
		node.DurationMS = ev.Usage.DurationMS
		return true

	case "task_notification":
		if !exists {
			node = &subagentNode{
				TaskID:    ev.TaskID,
				Name:      ev.SubagentType,
				StartedAt: now,
			}
			r.order = append(r.order, node)
			r.byID[ev.TaskID] = node
		}
		if ev.Usage.TotalTokens > 0 {
			node.Tokens = ev.Usage.TotalTokens
		}
		if ev.Usage.ToolUses > 0 {
			node.ToolUses = ev.Usage.ToolUses
		}
		if ev.Usage.DurationMS > 0 {
			node.DurationMS = ev.Usage.DurationMS
		}
		switch ev.Status {
		case "completed":
			node.Status = "done"
		case "failed":
			node.Status = "failed"
		default:
			node.Status = "done"
		}
		node.EndedAt = now
		return true
	}
	return false
}

// snapshot returns the current roster as the JSON-ready slice the
// view_event requires. Must be called under Session.mu.
func (r *subagentRegistry) snapshot() []map[string]any {
	out := make([]map[string]any, 0, len(r.order))
	for _, n := range r.order {
		m := map[string]any{
			"task_id":     n.TaskID,
			"name":        n.Name,
			"description": n.Description,
			"status":      n.Status,
			"last_tool":   n.LastTool,
			"tokens":      n.Tokens,
			"tool_uses":   n.ToolUses,
			"duration_ms": n.DurationMS,
			"started_at":  n.StartedAt.UTC().Format(time.RFC3339Nano),
			"ended_at":    endedAtStr(n.EndedAt),
		}
		out = append(out, m)
	}
	return out
}

func endedAtStr(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}

// subagentRegistryHandle is a thread-safe handle that wraps a registry
// plus its mutex, allowing processClaudeStreamOutput (which runs in a
// goroutine) to update and emit roster snapshots without holding
// Session.mu for the entire line processing duration. The lock is held
// only for the brief apply+snapshot critical section; the publish call
// runs outside the lock.
type subagentRegistryHandle struct {
	mu        *sync.Mutex
	reg       *subagentRegistry
	publish   func([]byte)
	sessionID string
}

// subagentHandle builds the handle that processClaudeStreamOutput uses to
// update the session's registry and emit roster view_events. The handle
// borrows s.mu and s.subagents (both live for the session lifetime), so
// it is safe to hold across process restarts — the Session owns the
// registry state.
func (s *Session) subagentHandle() *subagentRegistryHandle {
	return &subagentRegistryHandle{
		mu:        &s.mu,
		reg:       s.subagents,
		publish:   s.PublishText,
		sessionID: s.ID,
	}
}

// onTaskEvent is called from processClaudeStreamOutput for each task_*
// frame. It applies the event under the lock, builds the snapshot, then
// publishes the view_event without holding the lock.
func (h *subagentRegistryHandle) onTaskEvent(ev subagentTaskEvent) {
	if h == nil {
		return
	}
	now := time.Now()
	h.mu.Lock()
	changed := h.reg.apply(ev, now)
	var snap []map[string]any
	if changed {
		snap = h.reg.snapshot()
	}
	h.mu.Unlock()

	if !changed || len(snap) == 0 {
		return
	}
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "agents",
		"event": map[string]any{
			"agents": snap,
		},
	})
	if err != nil {
		return
	}
	h.publish(payload)
}
