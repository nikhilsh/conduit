package session

import "testing"

// Pins claudeCompactNotice against the real claude-code 2.1.156
// stream-json `/compact` events captured 2026-05-29.
func TestClaudeCompactNotice(t *testing.T) {
	cases := []struct {
		name, line, want string
		ok               bool
	}{
		{
			name: "compacting status",
			line: `{"type":"system","subtype":"status","status":"compacting","session_id":"s","uuid":"u"}`,
			want: "Compacting context…", ok: true,
		},
		{
			name: "compact success",
			line: `{"type":"system","subtype":"status","status":null,"compact_result":"success","session_id":"s"}`,
			want: "✓ Context compacted.", ok: true,
		},
		{
			name: "compact failed with error",
			line: `{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"Not enough messages to compact.","session_id":"s"}`,
			want: "Couldn’t compact: Not enough messages to compact.", ok: true,
		},
		{
			name: "init system event ignored",
			line: `{"type":"system","subtype":"init","slash_commands":["compact"]}`,
			ok:   false,
		},
		{
			name: "assistant line ignored",
			line: `{"type":"assistant","message":{"role":"assistant"}}`,
			ok:   false,
		},
		{name: "malformed ignored", line: `{nope`, ok: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := claudeCompactNotice([]byte(tc.line))
			if ok != tc.ok {
				t.Fatalf("ok=%v want %v (got %q)", ok, tc.ok, got)
			}
			if tc.ok && got != tc.want {
				t.Fatalf("got %q want %q", got, tc.want)
			}
		})
	}
}
