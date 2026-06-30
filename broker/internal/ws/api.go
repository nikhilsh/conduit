package ws

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/credentials"
	"github.com/nikhilsh/conduit/broker/internal/hostmetrics"
	"github.com/nikhilsh/conduit/broker/internal/push"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

type apiErrorEnvelope struct {
	Error apiError `json:"error"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, apiErrorEnvelope{
		Error: apiError{
			Code:    code,
			Message: message,
		},
	})
}

// authRejectLog rate-limits the 401 log line: at most one line per
// authRejectLogEvery, with a count of how many rejections it covers.
// Before this, auth rejections were completely silent server-side, which
// made device-reported 401s undiagnosable from the broker log.
var authRejectLog struct {
	sync.Mutex
	last       time.Time
	suppressed int
}

const authRejectLogEvery = 10 * time.Second

func logAuthReject(r *http.Request) {
	authRejectLog.Lock()
	defer authRejectLog.Unlock()
	if time.Since(authRejectLog.last) < authRejectLogEvery {
		authRejectLog.suppressed++
		return
	}
	extra := ""
	if n := authRejectLog.suppressed; n > 0 {
		extra = fmt.Sprintf(" (+%d suppressed)", n)
	}
	log.Printf("auth: rejected %s %s from %s%s", r.Method, r.URL.Path, r.RemoteAddr, extra)
	authRejectLog.last = time.Now()
	authRejectLog.suppressed = 0
}

func (s *Server) requireAuth(w http.ResponseWriter, r *http.Request) bool {
	if s.Auth.Check(r) {
		return true
	}
	logAuthReject(r)
	writeAPIError(w, http.StatusUnauthorized, "auth_expired", "unauthorized")
	return false
}

type capabilitiesResponse struct {
	Name       string   `json:"name"`
	Protocol   string   `json:"protocol"`
	Assistants []string `json:"assistants"`
	Endpoints  struct {
		Capabilities   bool `json:"capabilities"`
		FSList         bool `json:"fs_list"`
		SessionStart   bool `json:"session_start"`
		RecentProjects bool `json:"recent_projects"`
	} `json:"endpoints"`
	Features struct {
		WSCreateWithCWD   bool `json:"ws_create_with_cwd"`
		FSMetadata        bool `json:"fs_metadata"`
		FSPagination      bool `json:"fs_pagination"`
		SwitchAgent       bool `json:"switch_agent"`
		StructuredErrors  bool `json:"structured_errors"`
		TokenInQueryParam bool `json:"token_in_query_param"`
		// HostMetrics: GET /api/host/metrics serves CPU/MEM/DISK for the
		// Box health screen. False (or absent, on older brokers) → the
		// app hides the health section.
		HostMetrics bool `json:"host_metrics"`
		// ShellSessions: the hidden `shell` adapter exists, so the app may
		// create a plain terminal session on this box (Box health → SSH).
		ShellSessions bool `json:"shell_sessions"`
		// Push: broker supports POST /api/push/register + /api/push/unregister
		// + /api/push/test. Always true from this version forward; UnifiedPush
		// needs no relay, so the endpoint is always present.
		Push bool `json:"push"`
		// PushRelayConfigured: the CONDUIT_PUSH_RELAY_URL env var is set, so
		// APNs (iOS) and FCM (Android fallback) delivery is active. False means
		// only UnifiedPush (Android self-hosted) is wired.
		PushRelayConfigured bool `json:"push_relay_configured"`
		// NtfyURL: the base URL of a self-hosted ntfy server co-located with
		// this broker (set via CONDUIT_NTFY_URL, populated by
		// scripts/remote-bootstrap.sh --with-ntfy). When non-empty the Android
		// app can auto-configure UnifiedPush against it — no Firebase, no
		// third-party distributor. Absent / empty when ntfy is not configured.
		NtfyURL string `json:"ntfy_url,omitempty"`
		// SessionDiscovery: GET /api/sessions/discovered + /transcript are available.
		// Clients gate the Found Sessions UI on this flag.
		SessionDiscovery bool `json:"session_discovery"`
		// SessionFork: POST /api/sessions/adopt supports mode=fork (worktree fork).
		// True: fork-onto-worktree is fully implemented + tested (real --fork-session).
		SessionFork bool `json:"session_fork"`
		// SessionWatch: GET /api/sessions/discovered/transcript supports since_ts
		// for incremental polling. True from this version forward.
		SessionWatch bool `json:"session_watch"`
		// FanoutCompare: POST /api/fanout/compare is available. Apps gate
		// the Compare button on this flag so old brokers degrade gracefully.
		FanoutCompare bool `json:"fanout_compare"`
		// Pipeline: POST /api/pipeline + GET /api/pipeline/{id} + POST
		// /api/pipeline/{id}/continue + DELETE /api/pipeline/{id} +
		// GET /api/pipelines are available (sequential agent pipeline subsystem).
		Pipeline bool `json:"pipeline"`
	} `json:"features"`
	// Models is the per-assistant model+effort catalog discovered live from
	// the agent CLIs (claude control-protocol initialize, codex app-server
	// model/list). Omitted while discovery hasn't completed (or on older
	// brokers) — the apps then fall back to their built-in lists.
	//
	// KEPT for one release alongside the richer per-assistant `agents`
	// descriptors below: current apps still read this top-level map. Deprecate
	// after the descriptor-driven apps (Phase 3) ship.
	Models map[string][]session.ModelInfo `json:"models,omitempty"`
	// Agents is the per-assistant capability descriptor map (WS-2.3):
	// display_name, login_provider, supports{...} (from the protocol backend's
	// BackendCapabilities + the manifest's plan-mode rule), and the same
	// ModelInfo slice as Models[name]. The apps render from these with a static
	// fallback; an unknown agent degrades to a generic look. Omitted when no
	// assistant has a structured backend (only the legacy scrape path).
	Agents map[string]session.AgentDescriptor `json:"agents,omitempty"`
	// Readiness is the WS-H.1 connection-health block. It lets the app show
	// a post-pair checklist and a stale-broker prompt instead of letting
	// sessions fail cryptically:
	//   - broker_version: the ldflags-stamped tag/SHA (or "dev")
	//   - node_present:   termgrid sidecar availability (scrollback quality)
	//   - tmux_present:   session-recovery availability
	//   - agents:         per-agent CLI presence + sign-in state
	Readiness ReadinessBlock `json:"readiness"`
}

func (s *Server) serveCapabilities(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	resp := capabilitiesResponse{
		Name:       "conduit-broker",
		Protocol:   "2026-05-18",
		Assistants: s.Sessions.AssistantNames(),
	}
	resp.Endpoints.Capabilities = true
	resp.Endpoints.FSList = true
	resp.Endpoints.SessionStart = true
	resp.Endpoints.RecentProjects = true
	resp.Features.WSCreateWithCWD = true
	resp.Features.FSMetadata = true
	resp.Features.FSPagination = true
	resp.Features.SwitchAgent = true
	resp.Features.StructuredErrors = true
	resp.Features.TokenInQueryParam = true
	resp.Features.HostMetrics = hostmetrics.Available()
	resp.Features.ShellSessions = s.Sessions.HasAssistant("shell")
	resp.Features.Push = true
	resp.Features.PushRelayConfigured = s.PushRelayConfigured
	resp.Features.NtfyURL = s.NtfyURL
	resp.Features.SessionDiscovery = true
	resp.Features.SessionFork = true   // real worktree fork with --fork-session (this PR)
	resp.Features.SessionWatch = true  // since_ts incremental transcript polling
	resp.Features.FanoutCompare = true // POST /api/fanout/compare diff-stat endpoint
	resp.Features.Pipeline = true      // sequential agent pipeline subsystem
	resp.Models = s.Sessions.ModelCatalog()
	resp.Agents = s.Sessions.AgentDescriptors()
	// Pass the pushed-credential store as a nil INTERFACE when unset:
	// handing a typed-nil *credentials.Store through the credStore
	// interface would make `creds != nil` true and nil-deref on Has().
	var creds credStore
	if s.Credentials != nil {
		creds = s.Credentials
	}
	resp.Readiness = buildReadiness(s.Sessions, s.Sessions.Registry(), creds)
	writeJSON(w, http.StatusOK, resp)
}

// serveHostMetrics serves GET /api/host/metrics — the Box health screen's
// CPU/MEM/DISK source. 503 metrics_unavailable when the platform cannot
// report (the app treats that the same as an old broker: hide the section).
func (s *Server) serveHostMetrics(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	snap, ok := hostmetrics.Sample()
	if !ok {
		writeAPIError(w, http.StatusServiceUnavailable, "metrics_unavailable", "host metrics not supported on this box")
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

type startSessionRequest struct {
	SessionID string `json:"session_id"`
	Assistant string `json:"assistant"`
	CWD       string `json:"cwd"`
	// ReasoningEffort / Model are optional per-session overrides for the
	// fork-onto-a-different-model path. Empty = adapter defaults. Honored
	// only on create; an existing session keeps the effort/model it was
	// spawned with.
	ReasoningEffort string `json:"reasoning_effort"`
	Model           string `json:"model"`
	// PermissionMode selects the agent's permission posture ("" / "auto" =
	// full-auto default, "plan" = read-only planning). See override.go.
	PermissionMode string `json:"permission_mode"`
	// FastMode is the claude-only "fast mode" toggle. nil (field absent) =
	// unchanged; true/false ride to the adapter's --settings arg. Non-claude
	// adapters ignore it. See override.go.
	FastMode *bool `json:"fast_mode,omitempty"`
	// Branch is an optional worktree branch name for this session. When
	// CONDUIT_SESSION_WORKTREE is enabled and the session's cwd is a git
	// repo, the worktree is created on this branch name instead of the
	// default "conduit/session-<id>". Ignored when worktree mode is off.
	Branch string `json:"branch,omitempty"`
}

type startSessionResponse struct {
	SessionID       string `json:"session_id"`
	Assistant       string `json:"assistant"`
	CWD             string `json:"cwd"`
	ReasoningEffort string `json:"reasoning_effort,omitempty"`
	Model           string `json:"model,omitempty"`
	Created         bool   `json:"created"`
	WSPath          string `json:"ws_path"`
}

func (s *Server) serveSessionStart(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req startSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	id := strings.TrimSpace(req.SessionID)
	if id == "" {
		id = newSessionID()
	}
	assistant := strings.TrimSpace(req.Assistant)
	if assistant == "" {
		assistant = "claude"
	}
	cwd := strings.TrimSpace(req.CWD)
	if cwd != "" {
		if !filepath.IsAbs(cwd) {
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", "cwd must be an absolute path")
			return
		}
	}
	override := session.SpawnOverride{
		ReasoningEffort: strings.TrimSpace(req.ReasoningEffort),
		Model:           strings.TrimSpace(req.Model),
		PermissionMode:  strings.TrimSpace(req.PermissionMode),
		FastMode:        req.FastMode,
	}
	sess, created, err := s.Sessions.GetOrCreateWithOptions(id, assistant, session.CreateOptions{
		CWD:      cwd,
		Override: override,
		Branch:   strings.TrimSpace(req.Branch),
	})
	if err != nil {
		msg := err.Error()
		switch {
		case strings.Contains(msg, "unknown assistant"):
			writeAPIError(w, http.StatusBadRequest, "assistant_unknown", msg)
		case strings.Contains(msg, "invalid cwd"):
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", msg)
		case strings.Contains(msg, "gave up"):
			// Restart budget spent (session/restartbudget.go): the
			// session was archived and will not respawn. 410 so clients
			// can distinguish "ended for good" from a transient failure.
			writeAPIError(w, http.StatusGone, "session_gave_up", msg)
		case strings.Contains(msg, "session archived"):
			// Session was previously deleted; refuse the resurrect.
			// 410 Gone so clients can drop it from their list instead
			// of retrying endlessly.
			writeAPIError(w, http.StatusGone, "session_archived", msg)
		default:
			writeAPIError(w, http.StatusInternalServerError, "session_start_failed", msg)
		}
		return
	}
	resp := startSessionResponse{
		SessionID:       sess.ID,
		Assistant:       sess.Assistant,
		CWD:             cwd,
		ReasoningEffort: sess.ReasoningEffort(),
		Model:           override.Model,
		Created:         created,
		WSPath:          fmt.Sprintf("/ws/%s?assistant=%s", sess.ID, sess.Assistant),
	}
	s.Sessions.RecordRecentProject(sess.WorkspaceDir(), sess.Assistant, sess.ID)
	writeJSON(w, http.StatusOK, resp)
}

type recentProjectsResponse struct {
	Projects []session.RecentProject `json:"projects"`
}

func (s *Server) serveRecentProjects(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	limit := 20
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 || n > 100 {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid limit (must be 1..100)")
			return
		}
		limit = n
	}
	writeJSON(w, http.StatusOK, recentProjectsResponse{
		Projects: s.Sessions.RecentProjects(limit),
	})
}

// sessionsResponse is the body of GET /api/sessions — the authoritative
// list of sessions the broker is keeping alive RIGHT NOW (the live
// "what's running" set). A reconnecting client reconciles against this:
// only sessions present here (and `running`) belong in its ACTIVE list;
// everything else it had saved as live has died and drops to History.
type sessionsResponse struct {
	Sessions []session.LiveSessionInfo `json:"sessions"`
	// Recoverable lists cold on-disk sessions that are not live right now
	// but would respawn cleanly on open (the "dead now, resumable" set).
	// Kept SEPARATE from Sessions so listing never resurrects a process and
	// the live set keeps its strict "alive right now" meaning — the client
	// uses this purely to offer Resume on otherwise read-only rows.
	Recoverable []session.LiveSessionInfo `json:"recoverable,omitempty"`
}

// serveSessions returns the broker's in-memory live-session set. It never
// triggers recovery, so listing can't resurrect a dead/on-disk session
// into the ACTIVE list — that was the bug behind dead sessions showing as
// "running" after a relaunch.
func (s *Server) serveSessions(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, sessionsResponse{
		Sessions:    s.Sessions.LiveSessions(),
		Recoverable: s.Sessions.RecoverableSessions(),
	})
}

// sessionConversationResponse is the body of GET
// /api/session/conversation/<id>. `items` is the persisted transcript in
// ascending chronological order — the same `{role, content, ts, files}` shape
// the clients already render for live chat.
//
// Backward-pagination fields (present on every response):
//
//	has_more_before — true when older messages exist beyond this page.
//	oldest_ts       — unix-millisecond timestamp of the earliest item in `items`
//	                  (0 when items is empty). Use as the next before_ts cursor.
//	latest_ts       — unix-millisecond timestamp of the newest item in the FULL
//	                  transcript (0 when empty). Advances the since_ts cursor
//	                  even when a since_ts request returns no new items.
type sessionConversationResponse struct {
	Items         []session.ConvEntry `json:"items"`
	HasMoreBefore bool                `json:"has_more_before"`
	OldestTs      int64               `json:"oldest_ts"`
	LatestTs      int64               `json:"latest_ts"`
}

// serveSessionConversation returns a session's persisted conversation
// transcript by id. Works for live AND exited sessions (the broker
// appends both sides to a per-session conversation.jsonl that survives
// reap), so the app can reopen a past session read-only.
//
// Query params (all optional — omitting all returns the full transcript):
//
//	tail=N        — return the most recent N messages (initial bottom-anchor
//	                load). Ignored when before_ts or since_ts is set.
//	before_ts=T   — return up to `limit` messages STRICTLY OLDER than T
//	                (unix milliseconds). Use oldest_ts from the previous
//	                response as the next cursor. Mutually exclusive with
//	                since_ts; before_ts takes precedence.
//	since_ts=T    — return messages STRICTLY NEWER than T (unix milliseconds).
//	                Forward-delta polling cursor (unchanged from v1).
//	limit=N       — page size cap; default 80, clamp 1–500.
func (s *Server) serveSessionConversation(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/session/conversation/"))
	if id == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing session id")
		return
	}
	opts, ok := parsePageOpts(w, r)
	if !ok {
		return
	}
	all, err := s.Sessions.ConversationLog(id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "no conversation for session")
		return
	}
	page := session.ApplyPagination(all, opts)
	writeJSON(w, http.StatusOK, sessionConversationResponse{
		Items:         page.Items,
		HasMoreBefore: page.HasMoreBefore,
		OldestTs:      page.OldestTs,
		LatestTs:      page.LatestTs,
	})
}

// parsePageOpts extracts backward-pagination query params from the request.
// Returns (opts, true) on success; writes a 400 and returns (_, false) on
// invalid input.
func parsePageOpts(w http.ResponseWriter, r *http.Request) (session.TranscriptPageOpts, bool) {
	q := r.URL.Query()
	var opts session.TranscriptPageOpts

	if raw := strings.TrimSpace(q.Get("since_ts")); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v < 0 {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", "since_ts must be a non-negative unix millisecond timestamp")
			return opts, false
		}
		opts.SinceTs = v
	}
	if raw := strings.TrimSpace(q.Get("before_ts")); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v <= 0 {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", "before_ts must be a positive unix millisecond timestamp")
			return opts, false
		}
		opts.BeforeTs = v
	}
	if raw := strings.TrimSpace(q.Get("tail")); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v <= 0 {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", "tail must be a positive integer")
			return opts, false
		}
		opts.Tail = v
	}
	if raw := strings.TrimSpace(q.Get("limit")); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v <= 0 {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", "limit must be a positive integer")
			return opts, false
		}
		opts.Limit = v
	}
	return opts, true
}

// serveSessionDelete terminates and archives a session by id. It is the
// server side of the app's swipe-to-delete: it stops the agent process +
// PTY, kills the per-session tmux session, drops the session from the
// live Manager map, and archives the on-disk session dir out of the
// active set (conversation.jsonl + work/ are preserved under
// `archived-sessions/<id>`, reachable via GET
// /api/session/conversation/<id>).
//
// Idempotent: deleting an already-gone session returns 200. Only DELETE
// is accepted; the WS `exit` control still merely kills the process and
// leaves the session recoverable, which is why the broker accumulated
// stale sessions — this is the endpoint that actually removes them.
func (s *Server) serveSessionDelete(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}

	// Route git sub-paths before the DELETE-only check.
	// Paths: /api/session/{id}/git/commit
	//        /api/session/{id}/git/pr
	tail := strings.TrimPrefix(r.URL.Path, "/api/session/")
	if strings.HasSuffix(tail, "/git/commit") {
		sessionID := strings.TrimSuffix(tail, "/git/commit")
		s.serveSessionGitCommit(w, r, sessionID)
		return
	}
	if strings.HasSuffix(tail, "/git/pr") {
		sessionID := strings.TrimSuffix(tail, "/git/pr")
		s.serveSessionGitPR(w, r, sessionID)
		return
	}

	if r.Method != http.MethodDelete {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "DELETE required")
		return
	}
	id := strings.TrimSpace(tail)
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid session id")
		return
	}
	if err := s.Sessions.DeleteSession(id); err != nil {
		writeAPIError(w, http.StatusInternalServerError, "session_delete_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session_id": id,
		"deleted":    true,
	})
}

// pushRegisterRequest is the body for POST /api/push/register.
// session_id is required when platform="apns-liveactivity"; omitted for alert platforms.
// device_id is the stable per-install UUID sent by new app clients to enable
// per-device push targeting. Omitted by old clients; those tokens participate
// only in broadcast Notify.
type pushRegisterRequest struct {
	Platform  string `json:"platform"`
	Token     string `json:"token"`
	SessionID string `json:"session_id"`
	DeviceID  string `json:"device_id"`
}

// servePushRegister handles POST /api/push/register.
// The caller must supply a valid bearer token (requireAuth).
// Identity = pushIdentity (single-operator broker).
//
// Two registration paths:
//   - platform="apns-liveactivity": registers an LA push token keyed by
//     (identity, session_id); stored in the LARegistry, not the alert Registry.
//   - platform="apns"|"fcm"|"unifiedpush": existing alert registration (unchanged).
func (s *Server) servePushRegister(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req pushRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	platform := strings.TrimSpace(req.Platform)
	token := strings.TrimSpace(req.Token)
	sessionID := strings.TrimSpace(req.SessionID)
	deviceID := strings.TrimSpace(req.DeviceID)

	// LA token path: session-scoped, stored separately from alert tokens.
	if platform == "apns-liveactivity" {
		if token == "" {
			writeAPIError(w, http.StatusBadRequest, "invalid_token", "token is required")
			return
		}
		if sessionID == "" {
			writeAPIError(w, http.StatusBadRequest, "invalid_session_id", "session_id is required for apns-liveactivity")
			return
		}
		if s.LATokens == nil {
			// No LA registry wired — accept and silently discard so old brokers
			// without the registry don't 503 the iOS client.
			writeJSON(w, http.StatusOK, map[string]any{"registered": true, "platform": platform})
			return
		}
		s.LATokens.SetLA(pushIdentity, sessionID, token)
		log.Printf("push: registered apns-liveactivity token for session %s", sessionID)
		writeJSON(w, http.StatusOK, map[string]any{"registered": true, "platform": platform, "session_id": sessionID})
		return
	}

	// Standard alert registration path — stores device_id for per-device targeting.
	pp := push.Platform(platform)
	if !push.ValidPlatform(pp) {
		writeAPIError(w, http.StatusBadRequest, "invalid_platform", "platform must be apns, fcm, or unifiedpush")
		return
	}
	if token == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_token", "token is required")
		return
	}
	if s.Push == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "push_unavailable", "push registry not configured")
		return
	}
	dt := push.DeviceToken{Platform: pp, Token: token, DeviceID: deviceID}
	s.Push.Register(pushIdentity, dt)
	if deviceID != "" {
		log.Printf("push: registered %s token for %s device_id=%s", platform, pushIdentity, deviceID)
	} else {
		log.Printf("push: registered %s token for %s", platform, pushIdentity)
	}
	writeJSON(w, http.StatusOK, map[string]any{"registered": true, "platform": string(pp)})
}

// servePushRegisterStart handles POST /api/push/register-start.
// Stores the ActivityKit push-to-start token (device-scoped, session-less)
// in the persisted alert Registry under PlatformAPNsLiveActivityStart.
//
// Wire contract:
//
//	POST /api/push/register-start
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"platform":"apns-liveactivity-start","token":"<hex>"}
//	→ 200 {"registered":true}
//	  400 invalid_platform / invalid_token / invalid_request
//	  401 auth_expired
func (s *Server) servePushRegisterStart(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req pushRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	platform := strings.TrimSpace(req.Platform)
	token := strings.TrimSpace(req.Token)

	if platform != string(push.PlatformAPNsLiveActivityStart) {
		writeAPIError(w, http.StatusBadRequest, "invalid_platform", "platform must be apns-liveactivity-start")
		return
	}
	if token == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_token", "token is required")
		return
	}
	if s.Push == nil {
		// Forward-compat: if no registry is wired, accept and discard so old
		// brokers don't 503 the iOS client (same pattern as the LA no-registry branch).
		writeJSON(w, http.StatusOK, map[string]any{"registered": true})
		return
	}
	dt := push.DeviceToken{Platform: push.PlatformAPNsLiveActivityStart, Token: token}
	s.Push.Register(pushIdentity, dt)
	log.Printf("push: registered apns-liveactivity-start token for %s", pushIdentity)
	writeJSON(w, http.StatusOK, map[string]any{"registered": true})
}

// servePushUnregister handles POST /api/push/unregister.
func (s *Server) servePushUnregister(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req pushRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	platform := push.Platform(strings.TrimSpace(req.Platform))
	token := strings.TrimSpace(req.Token)
	if s.Push == nil {
		writeJSON(w, http.StatusOK, map[string]any{"unregistered": true})
		return
	}
	dt := push.DeviceToken{Platform: platform, Token: token}
	s.Push.Unregister(pushIdentity, dt)
	writeJSON(w, http.StatusOK, map[string]any{"unregistered": true, "platform": string(platform)})
}

// pushTestRequest is the body for POST /api/push/test.
// device_id, when non-empty, restricts the test push to tokens registered
// by that specific device (per-device targeting). If device_id is empty or
// no stored token matches it, the test falls back to broadcasting to all
// registered tokens (backward-compat with old clients and old tokens).
type pushTestRequest struct {
	Title    string `json:"title"`
	Body     string `json:"body"`
	DeviceID string `json:"device_id"`
}

// servePushTest handles POST /api/push/test — sends a test push to all
// tokens registered for the caller's identity. This is the end-to-end
// verification path: pair a device, register its token, hit this endpoint,
// and confirm the notification arrives on the device.
func (s *Server) servePushTest(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req pushTestRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	if s.Dispatcher == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "push_unavailable", "push dispatcher not configured")
		return
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = "Conduit test push"
	}
	body := strings.TrimSpace(req.Body)
	if body == "" {
		body = "Push notifications are working"
	}
	deviceID := strings.TrimSpace(req.DeviceID)
	payload := push.Payload{
		Title: title,
		Body:  body,
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	// Per-device targeting: if the caller supplied a device_id AND we have
	// at least one stored token for that device, send only to it.
	// Fallback to broadcast when device_id is empty (old client) or when
	// no stored token matches (e.g. token registered before device_id was
	// introduced). This ensures no push is ever silently dropped.
	targeted := false
	if deviceID != "" && s.Push != nil {
		if matched := s.Push.TokensForDevice(pushIdentity, deviceID); len(matched) > 0 {
			if err := s.Dispatcher.NotifyDevice(ctx, pushIdentity, deviceID, payload); err != nil {
				log.Printf("push test: notify device %s error: %v", deviceID, err)
				writeAPIError(w, http.StatusInternalServerError, "push_send_failed", err.Error())
				return
			}
			targeted = true
		}
	}
	if !targeted {
		if err := s.Dispatcher.Notify(ctx, pushIdentity, payload); err != nil {
			log.Printf("push test: notify error: %v", err)
			writeAPIError(w, http.StatusInternalServerError, "push_send_failed", err.Error())
			return
		}
	}

	tokens := s.Push.TokensFor(pushIdentity)
	writeJSON(w, http.StatusOK, map[string]any{
		"sent":        true,
		"token_count": len(tokens),
		"targeted":    targeted,
	})
}

// agentCredentialsRequest is the body for POST /api/agent/credentials and
// POST /api/agent/credentials/clear. `credential` is unused (empty) for the
// clear endpoint.
type agentCredentialsRequest struct {
	Provider   string          `json:"provider"`
	Kind       string          `json:"kind"`
	Credential json.RawMessage `json:"credential"`
}

// serveAgentCredentials handles POST /api/agent/credentials — the
// session-less twin of the in-session WS `set_agent_credentials` control
// message. Auto-propagate-on-connect needs to push a credential to a box
// the instant it connects, before any session exists; the WS control path
// only runs on a session-bound socket, so this HTTP endpoint is the seam.
//
// Identity = the request bearer (requireAuth), which is exactly the bearer
// the credentials.Store keys its per-identity subdir on, so the blob lands
// in the same place the in-session push would have written it. Encryption
// at rest is unchanged: this calls Store.Set, which seals with AES-256-GCM.
//
// Wire contract:
//
//	POST /api/agent/credentials
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"provider":"anthropic"|"openai","kind":"oauth","credential":{…}}
//
//	200 {"stored":true,"provider":"…"}
//	400 {"error:invalid_request|unknown_provider|unsupported_kind|empty_credential}
//	401 {"error:…}                 — missing/bad token
//	503 {"error:credentials_unavailable} — broker started without a store
func (s *Server) serveAgentCredentials(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	if s.Credentials == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "credentials_unavailable", "broker has no credentials store configured")
		return
	}
	var req agentCredentialsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	provider := strings.TrimSpace(req.Provider)
	if !credentials.ValidProvider(provider) {
		writeAPIError(w, http.StatusBadRequest, "unknown_provider", "unknown provider "+provider)
		return
	}
	// Stage 1 only ships the oauth kind — mirror the WS guard so the wire
	// schema fails loudly when the protocol extends to api_key/signed_jwt.
	if strings.TrimSpace(req.Kind) != "oauth" {
		writeAPIError(w, http.StatusBadRequest, "unsupported_kind", "unsupported kind "+req.Kind)
		return
	}
	if len(req.Credential) == 0 {
		writeAPIError(w, http.StatusBadRequest, "empty_credential", "empty credential payload")
		return
	}
	if err := s.Credentials.Set(provider, req.Credential); err != nil {
		writeAPIError(w, http.StatusInternalServerError, "credentials_store_failed", err.Error())
		return
	}
	log.Printf("credentials: stored pushed %s blob via HTTP (session-less)", provider)
	// Immediately propagate the fresh credential into any live sessions that
	// spawned without one — don't wait for the 60-second watchdog tick.
	// The 401 fires within the same connect sequence, before the watchdog fires.
	s.Sessions.RefreshAllSessionCredentials(provider)
	writeJSON(w, http.StatusOK, map[string]any{"stored": true, "provider": provider})
}

// serveAgentCredentialsClear handles POST /api/agent/credentials/clear —
// per-box sign-out. Removes ONLY the app-pushed `<provider>.enc` blob for
// the request identity; it never touches the box owner's host-HOME login
// files (Store.Delete enforces this). Idempotent: clearing a provider with
// nothing stored is a 200.
//
// Wire contract:
//
//	POST /api/agent/credentials/clear
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"provider":"anthropic"|"openai"}
//
//	200 {"cleared":true,"provider":"…"}
//	400 {"error:invalid_request|unknown_provider}
//	401 {"error:…}
//	503 {"error:credentials_unavailable}
func (s *Server) serveAgentCredentialsClear(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	if s.Credentials == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "credentials_unavailable", "broker has no credentials store configured")
		return
	}
	var req agentCredentialsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	provider := strings.TrimSpace(req.Provider)
	if !credentials.ValidProvider(provider) {
		writeAPIError(w, http.StatusBadRequest, "unknown_provider", "unknown provider "+provider)
		return
	}
	if err := s.Credentials.Delete(provider); err != nil {
		writeAPIError(w, http.StatusInternalServerError, "credentials_clear_failed", err.Error())
		return
	}
	log.Printf("credentials: cleared pushed %s blob via HTTP (per-box sign-out)", provider)
	writeJSON(w, http.StatusOK, map[string]any{"cleared": true, "provider": provider})
}

// approvalResolveRequest is the body for POST /api/session/approval.
type approvalResolveRequest struct {
	SessionID string `json:"session_id"`
	Decision  string `json:"decision"` // "approve" or "deny"
}

// serveSessionApproval handles POST /api/session/approval — resolves a pending
// approval from a push notification action without requiring the app to open.
//
// Wire contract:
//
//	POST /api/session/approval
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"session_id":"<id>","decision":"approve"|"deny"}
//
//	200 {"ok":true}           — approval found and resolved
//	400 {"error":…}           — bad JSON body or invalid decision
//	401 {"error":…}           — missing/bad token
//	404 {"error":"no_pending_approval","message":"…"} — session unknown or nothing pending
func (s *Server) serveSessionApproval(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req approvalResolveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.SessionID = strings.TrimSpace(req.SessionID)
	if req.SessionID == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "session_id is required")
		return
	}
	req.Decision = strings.TrimSpace(req.Decision)
	if req.Decision != "approve" && req.Decision != "deny" {
		writeAPIError(w, http.StatusBadRequest, "invalid_decision", "decision must be \"approve\" or \"deny\"")
		return
	}
	sess, ok := s.Sessions.Get(req.SessionID)
	if !ok {
		writeAPIError(w, http.StatusNotFound, "no_pending_approval", "session not found or no pending approval")
		return
	}
	if !sess.ResolveApproval(req.Decision) {
		writeAPIError(w, http.StatusNotFound, "no_pending_approval", "no pending approval for this session")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// answerAskRequest is the body for POST /api/session/answer.
type answerAskRequest struct {
	SessionID string `json:"session_id"`
	Answer    string `json:"answer"`
}

// serveSessionAnswer handles POST /api/session/answer — answers a pending
// AskUserQuestion from a push notification action without requiring the app
// to open.
//
// Wire contract:
//
//	POST /api/session/answer
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"session_id":"<id>","answer":"<text>"}
//
//	200 {"ok":true}           — ask found and answered
//	400 {"error":…}           — bad JSON body or missing answer
//	401 {"error":…}           — missing/bad token
//	404 {"error":"no_pending_ask","message":"…"} — session unknown or nothing pending
func (s *Server) serveSessionAnswer(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req answerAskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.SessionID = strings.TrimSpace(req.SessionID)
	if req.SessionID == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "session_id is required")
		return
	}
	req.Answer = strings.TrimSpace(req.Answer)
	if req.Answer == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "answer is required")
		return
	}
	sess, ok := s.Sessions.Get(req.SessionID)
	if !ok {
		writeAPIError(w, http.StatusNotFound, "no_pending_ask", "session not found or no pending ask")
		return
	}
	if !sess.AnswerPendingAsk(req.Answer) {
		writeAPIError(w, http.StatusNotFound, "no_pending_ask", "no pending ask for this session")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// devicePresenceRequest is the body for POST /api/device/presence.
// device_id may also be supplied as the ?device_id= query param; the JSON
// body takes precedence when both are present.
type devicePresenceRequest struct {
	DeviceID string `json:"device_id"`
}

// serveDevicePresence handles POST /api/device/presence.
// Records a foreground heartbeat from the calling device so the broker can
// suppress alert pushes while the app is alive and visible (even when the
// session WS is closed due to background throttling).
//
// Wire contract:
//
//	POST /api/device/presence
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"device_id":"<uuid>"}          (or ?device_id=<uuid>)
//
//	200 {}
//	400 {"error":"invalid_request","message":"device_id is required"}
//	401 {"error":"auth_expired","message":"unauthorized"}
func (s *Server) serveDevicePresence(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}

	// Accept device_id from JSON body or query param (body wins when both supplied).
	deviceID := strings.TrimSpace(r.URL.Query().Get("device_id"))
	var req devicePresenceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err == nil {
		if id := strings.TrimSpace(req.DeviceID); id != "" {
			deviceID = id
		}
	}
	if deviceID == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "device_id is required")
		return
	}

	if s.PresenceTracker != nil {
		s.PresenceTracker.Record(deviceID)
		log.Printf("presence: heartbeat recorded device_id=%s", deviceID)
	}
	writeJSON(w, http.StatusOK, map[string]any{})
}

func newSessionID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	// Set UUIDv4/version bits and render canonical form without extra deps.
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexed[0:8], hexed[8:12], hexed[12:16], hexed[16:20], hexed[20:32])
}

// ---------------------------------------------------------------------------
// Found Sessions endpoints
// ---------------------------------------------------------------------------

// serveDiscoveredSessions handles GET /api/sessions/discovered.
// Returns external Claude/Codex sessions (started outside Conduit), sorted
// recent-first, with deduplication against Conduit's own sessions.
//
// Query params:
//
//	q=<s>               case-insensitive substring filter over title/cwd/git_branch
//	agent=claude,codex  comma-separated; absent = both
func (s *Server) serveDiscoveredSessions(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	q := r.URL.Query().Get("q")
	agentParam := strings.TrimSpace(r.URL.Query().Get("agent"))
	var agents []string
	if agentParam != "" {
		for _, a := range strings.Split(agentParam, ",") {
			if a = strings.TrimSpace(a); a != "" {
				agents = append(agents, a)
			}
		}
	}
	resp := s.Sessions.DiscoverExternalSessions(q, agents)
	writeJSON(w, http.StatusOK, resp)
}

// serveDiscoveredTranscript handles GET /api/sessions/discovered/transcript.
// Returns the read-only transcript for an external session before adoption.
//
// Required query params:
//
//	agent=claude|codex
//	external_id=<id>
//
// Optional pagination params (same semantics as /api/session/conversation/<id>):
//
//	since_ts=<unix_ms>   — return ONLY items STRICTLY NEWER than this cursor.
//	                       Preserved from v1; ignored when before_ts is set.
//	before_ts=<unix_ms>  — return up to `limit` items STRICTLY OLDER than cursor.
//	tail=N               — return the last N items (initial bottom-anchor load).
//	limit=N              — page size cap; default 80, clamp 1–500.
//
// Response JSON:
//
//	items          — page in ascending timestamp order.
//	has_more_before — true when older messages exist beyond this page.
//	oldest_ts      — ts of earliest item in page (0 when empty); next before_ts.
//	latest_ts      — ts of newest item in the FULL transcript (0 when empty).
func (s *Server) serveDiscoveredTranscript(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	agent := strings.TrimSpace(r.URL.Query().Get("agent"))
	externalID := strings.TrimSpace(r.URL.Query().Get("external_id"))
	if agent == "" || externalID == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "agent and external_id are required")
		return
	}
	opts, ok := parsePageOpts(w, r)
	if !ok {
		return
	}
	all, _ := session.ExternalTranscript(agent, externalID)
	page := session.ApplyPagination(all, opts)
	writeJSON(w, http.StatusOK, map[string]any{
		"items":           page.Items,
		"has_more_before": page.HasMoreBefore,
		"oldest_ts":       page.OldestTs,
		"latest_ts":       page.LatestTs,
	})
}

// adoptRequest is the body for POST /api/sessions/adopt.
type adoptRequest struct {
	Agent      string `json:"agent"`       // "claude" | "codex"
	ExternalID string `json:"external_id"` // claude session uuid / codex thread id
	CWD        string `json:"cwd"`
	Mode       string `json:"mode"` // "resume" | "fork"
}

// serveAdoptSession handles POST /api/sessions/adopt.
// Creates a NEW Conduit session seeded to resume (or fork) an external session.
//
//   - mode=resume: pre-seeds ClaudeChatSessionID / CodexThreadID so the backend
//     resumes the external conversation via --resume / thread/resume.
//   - mode=fork: creates a NEW git worktree off the repo containing cwd, then
//     launches the agent with --resume <id> --fork-session (claude) or plain
//     resume into the new worktree (codex, which has no wire-level fork).
//     The original terminal session is never modified.
func (s *Server) serveAdoptSession(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req adoptRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.Agent = strings.TrimSpace(req.Agent)
	req.ExternalID = strings.TrimSpace(req.ExternalID)
	req.CWD = strings.TrimSpace(req.CWD)
	req.Mode = strings.TrimSpace(req.Mode)

	if req.Agent == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "agent is required")
		return
	}
	if req.ExternalID == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "external_id is required")
		return
	}
	if req.Mode == "" {
		req.Mode = "resume"
	}
	if req.Mode != "resume" && req.Mode != "fork" {
		writeAPIError(w, http.StatusBadRequest, "invalid_mode", "mode must be 'resume' or 'fork'")
		return
	}

	// Validate CWD when present.
	if req.CWD != "" {
		if !filepath.IsAbs(req.CWD) {
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", "cwd must be an absolute path")
			return
		}
	}

	// Mint a new Conduit session ID for this adoption.
	sessID := newSessionID()

	if req.Mode == "fork" {
		s.serveForkSession(w, req, sessID)
		return
	}

	// mode=resume: create the session with the external conversation seeded.
	// The ExternalID becomes the resume seed (ClaudeChatSessionID or CodexThreadID)
	// which the agent backend picks up when launching: --resume <id> for claude,
	// thread/resume for codex.
	opts := session.CreateOptions{
		CWD: req.CWD,
		ExternalResume: session.ExternalResumeOptions{
			Agent:      req.Agent,
			ExternalID: req.ExternalID,
		},
	}
	sess, _, err := s.Sessions.GetOrCreateWithOptions(sessID, req.Agent, opts)
	if err != nil {
		msg := err.Error()
		switch {
		case strings.Contains(msg, "unknown assistant"):
			writeAPIError(w, http.StatusBadRequest, "assistant_unknown", msg)
		case strings.Contains(msg, "invalid cwd"):
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", msg)
		case strings.Contains(msg, "gave up"):
			writeAPIError(w, http.StatusGone, "session_gave_up", msg)
		case strings.Contains(msg, "session archived"):
			writeAPIError(w, http.StatusGone, "session_archived", msg)
		default:
			writeAPIError(w, http.StatusInternalServerError, "adopt_failed", msg)
		}
		return
	}

	log.Printf("found-sessions: adopted %s session %s as conduit session %s (mode=%s)",
		req.Agent, req.ExternalID, sess.ID, req.Mode)

	writeJSON(w, http.StatusOK, map[string]any{
		"session_id": sess.ID,
		"ws_path":    fmt.Sprintf("/ws/%s?assistant=%s", sess.ID, req.Agent),
		"mode":       req.Mode,
	})
}

// serveForkSession handles mode=fork in POST /api/sessions/adopt.
//
// Fork strategy:
//  1. Resolve the git repo root for req.CWD. If cwd is inside a git repo,
//     create a new worktree at <conduitRoot>/sessions/<sessID>/fork-worktree
//     on a fresh branch conduit/fork-<short>. The original repo HEAD is
//     unchanged.
//  2. If cwd is NOT inside a git repo (or worktree creation fails), fall back
//     to a plain work directory. Claude still gets --fork-session; codex gets
//     plain resume. The isolation guarantee is weaker (no separate git state)
//     but the original session is still untouched.
//  3. Launch the agent in the new directory:
//     - claude: --resume <external_id> --fork-session  (new claude session id)
//     - codex:  plain resume into new worktree (codex has no wire-level fork)
func (s *Server) serveForkSession(w http.ResponseWriter, req adoptRequest, sessID string) {
	conduitRoot := s.Sessions.ConduitRoot()

	// Step 1: resolve the workspace for the fork.
	var worktreeDir string
	cwd := req.CWD
	if cwd == "" {
		// No cwd supplied — use a plain sessions/<id>/fork-work directory.
		worktreeDir = ""
	} else {
		repoRoot, isGit := session.FindGitRepoRoot(cwd)
		if isGit {
			// Create a new worktree at sessions/<id>/fork-worktree.
			wtPath := filepath.Join(conduitRoot, "sessions", sessID, "fork-worktree")
			_, err := session.CreateForkWorktree(repoRoot, wtPath, sessID)
			if err != nil {
				log.Printf("found-sessions: fork %s worktree add failed: %v", sessID, err)
				writeAPIError(w, http.StatusConflict, "fork_failed",
					"could not create git worktree: "+err.Error())
				return
			}
			worktreeDir = wtPath
			log.Printf("found-sessions: fork %s git worktree created at %s (repo %s)", sessID, wtPath, repoRoot)
		} else {
			// cwd is not inside a git repo — use a plain directory.
			// The session runs in the original cwd but with an isolated broker session.
			worktreeDir = ""
			cwd = req.CWD
			log.Printf("found-sessions: fork %s — cwd %s is not a git repo; using plain cwd isolation", sessID, cwd)
		}
	}

	// Effective CWD for the new session.
	effectiveCWD := worktreeDir
	if effectiveCWD == "" {
		effectiveCWD = cwd
	}

	opts := session.CreateOptions{
		CWD: effectiveCWD,
		ExternalFork: session.ExternalForkOptions{
			Agent:       req.Agent,
			ExternalID:  req.ExternalID,
			WorktreeDir: worktreeDir,
		},
	}
	sess, _, err := s.Sessions.GetOrCreateWithOptions(sessID, req.Agent, opts)
	if err != nil {
		msg := err.Error()
		switch {
		case strings.Contains(msg, "unknown assistant"):
			writeAPIError(w, http.StatusBadRequest, "assistant_unknown", msg)
		case strings.Contains(msg, "invalid cwd"):
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", msg)
		case strings.Contains(msg, "gave up"):
			writeAPIError(w, http.StatusGone, "session_gave_up", msg)
		case strings.Contains(msg, "session archived"):
			writeAPIError(w, http.StatusGone, "session_archived", msg)
		default:
			writeAPIError(w, http.StatusInternalServerError, "fork_failed", msg)
		}
		return
	}

	log.Printf("found-sessions: forked %s session %s as conduit session %s (worktree=%s)",
		req.Agent, req.ExternalID, sess.ID, worktreeDir)

	writeJSON(w, http.StatusOK, map[string]any{
		"session_id": sess.ID,
		"ws_path":    fmt.Sprintf("/ws/%s?assistant=%s", sess.ID, req.Agent),
		"mode":       "fork",
	})
}
