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
	resp.Models = s.Sessions.ModelCatalog()
	resp.Agents = s.Sessions.AgentDescriptors()
	resp.Readiness = buildReadiness(s.Sessions, s.Sessions.Registry())
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
	sess, created, err := s.Sessions.GetOrCreateWithOptions(id, assistant, session.CreateOptions{CWD: cwd, Override: override})
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
// chronological order — the same `{role, content, ts, files}` shape the
// clients already render for live chat.
type sessionConversationResponse struct {
	Items []session.ConvEntry `json:"items"`
}

// serveSessionConversation returns a session's persisted conversation
// transcript by id. Works for live AND exited sessions (the broker
// appends both sides to a per-session conversation.jsonl that survives
// reap), so the app can reopen a past session read-only.
func (s *Server) serveSessionConversation(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/session/conversation/"))
	if id == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing session id")
		return
	}
	items, err := s.Sessions.ConversationLog(id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "no conversation for session")
		return
	}
	writeJSON(w, http.StatusOK, sessionConversationResponse{Items: items})
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
	if r.Method != http.MethodDelete {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "DELETE required")
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/session/"))
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
type pushRegisterRequest struct {
	Platform  string `json:"platform"`
	Token     string `json:"token"`
	SessionID string `json:"session_id"`
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

	// Standard alert registration path — unchanged.
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
	dt := push.DeviceToken{Platform: pp, Token: token}
	s.Push.Register(pushIdentity, dt)
	log.Printf("push: registered %s token for %s", platform, pushIdentity)
	writeJSON(w, http.StatusOK, map[string]any{"registered": true, "platform": string(pp)})
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
type pushTestRequest struct {
	Title string `json:"title"`
	Body  string `json:"body"`
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
	payload := push.Payload{
		Title: title,
		Body:  body,
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	if err := s.Dispatcher.Notify(ctx, pushIdentity, payload); err != nil {
		log.Printf("push test: notify error: %v", err)
		writeAPIError(w, http.StatusInternalServerError, "push_send_failed", err.Error())
		return
	}
	tokens := s.Push.TokensFor(pushIdentity)
	writeJSON(w, http.StatusOK, map[string]any{
		"sent":        true,
		"token_count": len(tokens),
	})
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

func newSessionID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	// Set UUIDv4/version bits and render canonical form without extra deps.
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexed[0:8], hexed[8:12], hexed[12:16], hexed[16:20], hexed[20:32])
}
