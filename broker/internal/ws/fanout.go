package ws

// fanout.go — POST /api/fanout/compare handler.
//
// Accepts a list of session IDs (one per fan-out run) and returns per-run
// diff stats (files changed, insertions, deletions, raw diff_stat text) plus
// the last assistant message from each run's transcript.
//
// Design notes:
//   - Always returns HTTP 200. Per-run failures (missing session, missing
//     worktree, git error) are flagged via the `error` field on that run's
//     entry; the other runs are unaffected.
//   - No persistent fan-out object: the app holds the session-id list and
//     passes it on every call (v1 design per PLAN-FANOUT-COMPARE.md §1).

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/nikhilsh/conduit/broker/internal/session"
)

// fanoutCompareRunRequest is one run entry in the POST /api/fanout/compare
// request body.
type fanoutCompareRunRequest struct {
	SessionID string `json:"session_id"`
	Label     string `json:"label"`
}

// fanoutCompareRequest is the full body of POST /api/fanout/compare.
type fanoutCompareRequest struct {
	Base string                    `json:"base"`
	Runs []fanoutCompareRunRequest `json:"runs"`
}

// fanoutCompareRunResult is one entry in the response `runs` array.
type fanoutCompareRunResult struct {
	SessionID    string `json:"session_id"`
	Label        string `json:"label"`
	Phase        string `json:"phase"`
	FilesChanged int    `json:"files_changed"`
	Insertions   int    `json:"insertions"`
	Deletions    int    `json:"deletions"`
	DiffStat     string `json:"diff_stat"`
	AgentSummary string `json:"agent_summary"`
	Error        string `json:"error,omitempty"`
}

// fanoutCompareResponse is the response body of POST /api/fanout/compare.
type fanoutCompareResponse struct {
	Base string                   `json:"base"`
	Runs []fanoutCompareRunResult `json:"runs"`
}

const agentSummaryMaxChars = 200

// serveFanoutCompare handles POST /api/fanout/compare.
//
// Wire contract:
//
//	POST /api/fanout/compare
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{
//	  "base": "main",
//	  "runs": [
//	    { "session_id": "...", "label": "fix/ratelimit-a" },
//	    ...
//	  ]
//	}
//
//	200 { "base": "main", "runs": [...] }
//	400 — bad JSON body or missing base
//	401 — auth
func (s *Server) serveFanoutCompare(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req fanoutCompareRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.Base = strings.TrimSpace(req.Base)
	if req.Base == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "base is required")
		return
	}

	log.Printf("fanout/compare: base=%s runs=%d", req.Base, len(req.Runs))

	results := make([]fanoutCompareRunResult, 0, len(req.Runs))
	for _, run := range req.Runs {
		result := buildRunResult(s, run, req.Base)
		results = append(results, result)
	}

	writeJSON(w, http.StatusOK, fanoutCompareResponse{
		Base: req.Base,
		Runs: results,
	})
}

// buildRunResult resolves one fan-out run's diff stats and agent summary.
// All errors are captured into the result's Error field; the caller always
// gets a 200 with the run flagged rather than a handler-level error.
func buildRunResult(s *Server, run fanoutCompareRunRequest, base string) fanoutCompareRunResult {
	result := fanoutCompareRunResult{
		SessionID: run.SessionID,
		Label:     run.Label,
	}

	// 1. Look up the session.
	sess, ok := s.Sessions.Get(run.SessionID)
	if !ok {
		result.Error = "session not found: " + run.SessionID
		log.Printf("fanout/compare: session %s not found", run.SessionID)
		return result
	}

	// Capture phase.
	st := sess.Status()
	result.Phase = st.Phase

	// 2. Get the session's worktree dir.
	workdir := sess.WorkspaceDir()
	if workdir == "" {
		result.Error = "session has no working directory"
		log.Printf("fanout/compare: session %s has empty workdir", run.SessionID)
		return result
	}

	// 3. Run git diff --stat.
	files, ins, del, stat, err := session.DiffSummary(workdir, base)
	if err != nil {
		result.Error = err.Error()
		log.Printf("fanout/compare: session %s DiffSummary error: %v", run.SessionID, err)
		// Don't return early — still fetch agent summary below.
	} else {
		result.FilesChanged = files
		result.Insertions = ins
		result.Deletions = del
		result.DiffStat = stat
	}

	// 4. Get the last assistant message from the transcript (truncated to
	//    agentSummaryMaxChars). Empty when unavailable — never fabricated.
	result.AgentSummary = lastAssistantSummary(s, run.SessionID)

	return result
}

// lastAssistantSummary reads the session's conversation log and returns the
// last assistant message truncated to agentSummaryMaxChars. Returns "" when
// the transcript is unavailable or contains no assistant messages.
func lastAssistantSummary(s *Server, sessionID string) string {
	entries, err := s.Sessions.ConversationLog(sessionID)
	if err != nil || len(entries) == 0 {
		return ""
	}
	// Walk backwards for the last assistant entry.
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		if e.Role != "assistant" {
			continue
		}
		text := strings.TrimSpace(e.Content)
		if text == "" {
			continue
		}
		// Truncate to at most agentSummaryMaxChars runes.
		if utf8.RuneCountInString(text) > agentSummaryMaxChars {
			runes := []rune(text)
			text = string(runes[:agentSummaryMaxChars])
		}
		return text
	}
	return ""
}
