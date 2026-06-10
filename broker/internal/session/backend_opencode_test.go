package session

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// stubOpencodeServer is a canned opencode HTTP+SSE server for backend tests: it
// serves /global/health, POST /session, GET /event (SSE), POST
// /session/{id}/prompt_async (204 + scripted frames), POST /session/{id}/abort,
// and GET /config/providers — the slice WS-4.2 drives. Frames pushed to the
// open SSE stream are the verbatim shapes from docs/OPENCODE-PROTOCOL.md.
type stubOpencodeServer struct {
	srv     *httptest.Server
	sid     string
	mu      sync.Mutex
	sseW    http.ResponseWriter
	sseF    http.Flusher
	sseOpen chan struct{}
	aborts  int
}

func newStubOpencodeServer(sid string) *stubOpencodeServer {
	s := &stubOpencodeServer{sid: sid, sseOpen: make(chan struct{})}
	mux := http.NewServeMux()
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"healthy":true,"version":"1.17.0"}`)
	})
	mux.HandleFunc("/session", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":%q,"slug":"x","projectID":"global","version":"1.17.0"}`, s.sid)
	})
	mux.HandleFunc("/config/providers", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"providers":[{"id":"opencode","name":"OpenCode Zen","models":{"big-pickle":{"id":"big-pickle","name":"Big Pickle"}}}],"default":{"opencode":"big-pickle"}}`)
	})
	mux.HandleFunc("/event", func(w http.ResponseWriter, r *http.Request) {
		f, _ := w.(http.Flusher)
		w.Header().Set("content-type", "text/event-stream")
		fmt.Fprint(w, "data: {\"id\":\"evt_0\",\"type\":\"server.connected\",\"properties\":{}}\n\n")
		if f != nil {
			f.Flush()
		}
		s.mu.Lock()
		s.sseW, s.sseF = w, f
		s.mu.Unlock()
		close(s.sseOpen)
		<-r.Context().Done() // hold the stream open until the client cancels
	})
	mux.HandleFunc("/session/"+sid+"/prompt_async", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
		go s.scriptTurn()
	})
	mux.HandleFunc("/session/"+sid+"/abort", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.aborts++
		s.mu.Unlock()
		fmt.Fprint(w, "true")
		// An abort settles the stream to idle.
		go s.push(fmt.Sprintf(`{"id":"evt_ab","type":"session.idle","properties":{"sessionID":%q}}`, s.sid))
	})
	s.srv = httptest.NewServer(mux)
	return s
}

// push writes one SSE data frame to the open stream.
func (s *stubOpencodeServer) push(jsonBody string) {
	s.mu.Lock()
	w, f := s.sseW, s.sseF
	s.mu.Unlock()
	if w == nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", jsonBody)
	if f != nil {
		f.Flush()
	}
}

// scriptTurn pushes the verbatim turn lifecycle: busy → reasoning (dropped) →
// answer text → step-finish → idle. The answer is "PONG".
func (s *stubOpencodeServer) scriptTurn() {
	sid := s.sid
	frames := []string{
		fmt.Sprintf(`{"type":"session.status","properties":{"sessionID":%q,"status":{"type":"busy"}}}`, sid),
		fmt.Sprintf(`{"type":"message.part.updated","properties":{"sessionID":%q,"part":{"id":"prt_r","messageID":"msg_a","type":"reasoning","text":""}}}`, sid),
		fmt.Sprintf(`{"type":"message.part.delta","properties":{"sessionID":%q,"messageID":"msg_a","partID":"prt_r","field":"text","delta":"thinking"}}`, sid),
		fmt.Sprintf(`{"type":"message.part.updated","properties":{"sessionID":%q,"part":{"id":"prt_t","messageID":"msg_a","type":"text","text":""}}}`, sid),
		fmt.Sprintf(`{"type":"message.part.delta","properties":{"sessionID":%q,"messageID":"msg_a","partID":"prt_t","field":"text","delta":"PON"}}`, sid),
		fmt.Sprintf(`{"type":"message.part.delta","properties":{"sessionID":%q,"messageID":"msg_a","partID":"prt_t","field":"text","delta":"G"}}`, sid),
		fmt.Sprintf(`{"type":"message.part.updated","properties":{"sessionID":%q,"part":{"id":"prt_t","messageID":"msg_a","type":"text","text":"PONG"}}}`, sid),
		fmt.Sprintf(`{"type":"message.part.updated","properties":{"sessionID":%q,"part":{"id":"prt_sf","messageID":"msg_a","type":"step-finish","reason":"stop","tokens":{"total":10,"input":8,"output":2,"cache":{"read":0,"write":0}}}}}`, sid),
		fmt.Sprintf(`{"type":"session.idle","properties":{"sessionID":%q}}`, sid),
	}
	for _, fr := range frames {
		s.push(fr)
		time.Sleep(2 * time.Millisecond)
	}
}

// scriptErrorTurn pushes a turn that fails: busy → session.error (verbatim
// shape from live opencode 1.17.0) with NO trailing session.idle. This is the
// "typing forever, no reply" hang — the backend must end the turn on the error
// frame, not wait for an idle that never comes.
func (s *stubOpencodeServer) scriptErrorTurn() {
	sid := s.sid
	frames := []string{
		fmt.Sprintf(`{"type":"session.status","properties":{"sessionID":%q,"status":{"type":"busy"}}}`, sid),
		// Verbatim error shape: properties.error.{name,data.message}. No idle follows.
		fmt.Sprintf(`{"type":"session.error","properties":{"sessionID":%q,"error":{"name":"APIError","data":{"message":"upstream model is overloaded","statusCode":529}}}}`, sid),
	}
	for _, fr := range frames {
		s.push(fr)
		time.Sleep(2 * time.Millisecond)
	}
}

func (s *stubOpencodeServer) close() { s.srv.Close() }

// newTestOpencodeProcess builds an opencodeServerProcess pointed at the stub's
// baseURL and runs connect() (SSE + POST /session), skipping the real binary
// spawn. Returns the live process; caller defers Close.
func newTestOpencodeProcess(t *testing.T, base string, publish func([]byte), onSession func(string)) *opencodeServerProcess {
	t.Helper()
	c := &opencodeServerProcess{
		publish:        publish,
		onSession:      onSession,
		baseURL:        base,
		hc:             &http.Client{Timeout: 5 * time.Second},
		silenceTimeout: opencodeTurnSilenceTimeout,
	}
	if err := c.connect(); err != nil {
		t.Fatalf("connect: %v", err)
	}
	return c
}

func TestOpencodeBackend_TurnEndToEnd(t *testing.T) {
	stub := newStubOpencodeServer("ses_test1")
	defer stub.close()

	events := make(chan []byte, 64)
	sessions := make(chan string, 4)
	proc := newTestOpencodeProcess(t, stub.srv.URL,
		func(p []byte) { events <- p },
		func(id string) { sessions <- id },
	)
	defer proc.Close()

	// Session id latched + persisted.
	select {
	case id := <-sessions:
		if id != "ses_test1" {
			t.Fatalf("latched session = %q", id)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no session id latched")
	}

	if err := proc.Send("reply with exactly: PONG"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// Expect exactly one assistant bubble with the consolidated answer (reasoning dropped).
	deadline := time.After(3 * time.Second)
	var gotAssistant string
	for gotAssistant == "" {
		select {
		case p := <-events:
			role, content := chatEventRoleContent(p)
			if role == "assistant" {
				gotAssistant = content
			}
		case <-deadline:
			t.Fatal("timeout waiting for assistant bubble")
		}
	}
	if gotAssistant != "PONG" {
		t.Fatalf("assistant bubble = %q, want PONG", gotAssistant)
	}

	// Turn cleared after idle.
	waitFor(t, 2*time.Second, func() bool { return !proc.TurnActive() })
}

// TestOpencodeBackend_SessionErrorEndsTurn is the regression for the
// device-reported "typing forever, no reply" hang: a turn that goes busy then
// emits session.error with NO trailing session.idle must (1) clear turn_active
// so the composer's typing indicator stops, and (2) surface the error cause in
// the Chat tab as a system message — not silently spin.
func TestOpencodeBackend_SessionErrorEndsTurn(t *testing.T) {
	stub := newStubOpencodeServer("ses_err")
	defer stub.close()

	events := make(chan []byte, 64)
	proc := newTestOpencodeProcess(t, stub.srv.URL, func(p []byte) { events <- p }, func(string) {})
	defer proc.Close()

	stub.scriptErrorTurn()

	// The turn must clear despite no session.idle ever arriving.
	waitFor(t, 2*time.Second, func() bool { return !proc.TurnActive() })

	// And the cause must surface as a system bubble (not silence, not assistant).
	deadline := time.After(2 * time.Second)
	var sysContent string
	for sysContent == "" {
		select {
		case p := <-events:
			role, content := chatEventRoleContent(p)
			if role == "assistant" {
				t.Fatalf("unexpected assistant bubble for an errored turn: %q", content)
			}
			if role == "system" {
				sysContent = content
			}
		case <-deadline:
			t.Fatal("timeout waiting for the error system message")
		}
	}
	if !strings.Contains(sysContent, "APIError") || !strings.Contains(sysContent, "overloaded") {
		t.Fatalf("system message = %q, want it to carry the error name + cause", sysContent)
	}
}

// TestOpencodeBackend_AbortErrorIsQuiet: a MessageAbortedError (the abort
// terminus) must end the turn WITHOUT a scary error bubble — the Stop button
// already gave the user feedback.
func TestOpencodeBackend_AbortErrorIsQuiet(t *testing.T) {
	stub := newStubOpencodeServer("ses_abort")
	defer stub.close()

	events := make(chan []byte, 64)
	proc := newTestOpencodeProcess(t, stub.srv.URL, func(p []byte) { events <- p }, func(string) {})
	defer proc.Close()

	stub.push(`{"type":"session.status","properties":{"sessionID":"ses_abort","status":{"type":"busy"}}}`)
	waitFor(t, 2*time.Second, func() bool { return proc.TurnActive() })
	stub.push(`{"type":"session.error","properties":{"sessionID":"ses_abort","error":{"name":"MessageAbortedError","data":{"message":"aborted"}}}}`)
	waitFor(t, 2*time.Second, func() bool { return !proc.TurnActive() })

	select {
	case p := <-events:
		if role, content := chatEventRoleContent(p); role == "system" {
			t.Fatalf("abort should be quiet, got system bubble: %q", content)
		}
	case <-time.After(200 * time.Millisecond):
		// good — no bubble
	}
}

// TestOpencodeBackend_HeartbeatDoesNotStarveWatchdog is the regression for the
// REAL device hang that survived #459: a turn goes busy, the hosted provider
// then stalls (rate-limited / slow / down) emitting NO further per-session
// frames and NO session.idle/session.error — but opencode keeps the SSE alive
// with a server-wide `server.heartbeat` (no sessionID) every ~10s. Those
// heartbeats MUST NOT reset the per-turn silence watchdog, or the 10-minute
// backstop never fires and the composer's typing indicator spins forever.
// Drives handleEvent directly (no real server) for a deterministic check.
func TestOpencodeBackend_HeartbeatDoesNotStarveWatchdog(t *testing.T) {
	events := make(chan []byte, 8)
	c := &opencodeServerProcess{
		publish:        func(p []byte) { events <- p },
		sessionID:      "ses_hb",
		silenceTimeout: 60 * time.Millisecond,
	}
	// Start a turn (busy for our session).
	c.handleEvent(opencodeEvent{
		Type:       "session.status",
		Properties: opencodeEventProperties{SessionID: "ses_hb", Status: &opencodeStatus{Type: "busy"}},
	})
	if !c.TurnActive() {
		t.Fatal("turn should be active after busy")
	}
	// Pump server-wide heartbeats (empty sessionID) faster than the silence
	// window. Pre-fix these reset lastActivity and the watchdog never fired.
	hb := opencodeEvent{Type: "server.heartbeat"}
	stop := make(chan struct{})
	go func() {
		tk := time.NewTicker(15 * time.Millisecond)
		defer tk.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tk.C:
				c.handleEvent(hb)
			}
		}
	}()
	defer close(stop)

	// The watchdog must still fire and surface the no-response system message.
	waitForSystemEvent(t, events, "no response from the agent")
	if c.TurnActive() {
		t.Fatal("turn should be cleared after the watchdog fires")
	}
}

// TestOpencodeBackend_StaleSessionRecreatedOnSend covers the resume-after-DB-
// loss path: the persisted ses_ id no longer exists (opencode's global store was
// wiped/rotated), so prompt_async 404s with no SSE frames. The backend must
// create a fresh session, re-persist the new id, and retry the prompt once —
// rather than bouncing every turn with a "prompt rejected (404)" forever.
func TestOpencodeBackend_StaleSessionRecreatedOnSend(t *testing.T) {
	const staleID, freshID = "ses_stale", "ses_fresh"
	var (
		mu       sync.Mutex
		sseW     http.ResponseWriter
		sseF     http.Flusher
		sseReady = make(chan struct{})
		promptsF int // prompts that hit the fresh id
	)
	push := func(body string) {
		mu.Lock()
		w, f := sseW, sseF
		mu.Unlock()
		if w == nil {
			return
		}
		fmt.Fprintf(w, "data: %s\n\n", body)
		if f != nil {
			f.Flush()
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"healthy":true,"version":"1.17.0"}`)
	})
	mux.HandleFunc("/session", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":%q,"projectID":"global"}`, freshID)
	})
	mux.HandleFunc("/event", func(w http.ResponseWriter, r *http.Request) {
		f, _ := w.(http.Flusher)
		w.Header().Set("content-type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"server.connected\",\"properties\":{}}\n\n")
		if f != nil {
			f.Flush()
		}
		mu.Lock()
		sseW, sseF = w, f
		mu.Unlock()
		close(sseReady)
		<-r.Context().Done()
	})
	mux.HandleFunc("/session/"+staleID+"/prompt_async", func(w http.ResponseWriter, r *http.Request) {
		// Stale session no longer exists in the (rotated) store.
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprintf(w, `{"name":"NotFoundError","data":{"message":"Session not found: %s"}}`, staleID)
	})
	mux.HandleFunc("/session/"+freshID+"/prompt_async", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		promptsF++
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
		go func() {
			push(fmt.Sprintf(`{"type":"session.status","properties":{"sessionID":%q,"status":{"type":"busy"}}}`, freshID))
			push(fmt.Sprintf(`{"type":"message.part.updated","properties":{"sessionID":%q,"part":{"id":"prt_t","type":"text","text":"recovered"}}}`, freshID))
			push(fmt.Sprintf(`{"type":"session.idle","properties":{"sessionID":%q}}`, freshID))
		}()
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	events := make(chan []byte, 16)
	relatched := make(chan string, 2)
	c := &opencodeServerProcess{
		publish:        func(p []byte) { events <- p },
		onSession:      func(id string) { relatched <- id },
		sessionID:      staleID, // resume the stale id
		baseURL:        srv.URL,
		hc:             &http.Client{Timeout: 5 * time.Second},
		silenceTimeout: opencodeTurnSilenceTimeout,
	}
	if err := c.connect(); err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()
	<-sseReady

	if err := c.Send("hi"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// The recovered session id must be persisted for the next resume.
	select {
	case id := <-relatched:
		if id != freshID {
			t.Fatalf("re-latched %q, want %q", id, freshID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("stale session was not recreated/re-latched")
	}

	// The retried prompt must produce a real assistant bubble — no "rejected".
	deadline := time.After(2 * time.Second)
	for {
		select {
		case p := <-events:
			role, content := chatEventRoleContent(p)
			if role == "system" {
				t.Fatalf("unexpected system bubble (should self-heal): %q", content)
			}
			if role == "assistant" {
				if content != "recovered" {
					t.Fatalf("assistant bubble = %q, want recovered", content)
				}
				mu.Lock()
				n := promptsF
				mu.Unlock()
				if n != 1 {
					t.Fatalf("fresh prompt issued %d times, want 1", n)
				}
				return
			}
		case <-deadline:
			t.Fatal("no assistant bubble after stale-session recovery")
		}
	}
}

func TestOpencodeBackend_Interrupt(t *testing.T) {
	stub := newStubOpencodeServer("ses_int")
	defer stub.close()

	events := make(chan []byte, 64)
	proc := newTestOpencodeProcess(t, stub.srv.URL, func(p []byte) { events <- p }, func(string) {})
	defer proc.Close()

	// Drive a turn to busy by pushing only the busy frame directly.
	stub.push(`{"type":"session.status","properties":{"sessionID":"ses_int","status":{"type":"busy"}}}`)
	waitFor(t, 2*time.Second, func() bool { return proc.TurnActive() })

	if err := proc.Interrupt(); err != nil {
		t.Fatalf("Interrupt: %v", err)
	}
	// The stub's abort handler pushes session.idle → turn clears, quietly.
	waitFor(t, 2*time.Second, func() bool { return !proc.TurnActive() })

	stub.mu.Lock()
	aborts := stub.aborts
	stub.mu.Unlock()
	if aborts != 1 {
		t.Fatalf("abort called %d times, want 1", aborts)
	}
	// No assistant bubble should be emitted for an interrupted (no-prose) turn.
	select {
	case p := <-events:
		if role, _ := chatEventRoleContent(p); role == "assistant" {
			t.Fatalf("unexpected assistant bubble after interrupt: %q", p)
		}
	default:
	}
}

func TestOpencodeBackend_Resume_NoCreateSession(t *testing.T) {
	stub := newStubOpencodeServer("ses_should_not_create")
	defer stub.close()

	created := make(chan string, 1)
	// Seed a prior ses_ id: connect() must NOT POST /session (resume path).
	c := &opencodeServerProcess{
		publish:        func([]byte) {},
		onSession:      func(id string) { created <- id },
		sessionID:      "ses_resumed",
		baseURL:        stub.srv.URL,
		hc:             &http.Client{Timeout: 5 * time.Second},
		silenceTimeout: opencodeTurnSilenceTimeout,
	}
	if err := c.connect(); err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()

	select {
	case id := <-created:
		t.Fatalf("resume path should not latch a NEW session, got %q", id)
	case <-time.After(300 * time.Millisecond):
		// good — no new session created
	}
	if c.sessionID != "ses_resumed" {
		t.Fatalf("sessionID = %q, want ses_resumed", c.sessionID)
	}
}

func TestOpencodeBackend_CatalogProbeFromStub(t *testing.T) {
	stub := newStubOpencodeServer("ses_cat")
	defer stub.close()

	// Probe the stub's /config/providers directly (probeOpencodeCatalog spawns
	// a real binary, so exercise the HTTP+mapping leg via a direct GET here).
	resp, err := http.Get(stub.srv.URL + "/config/providers")
	if err != nil {
		t.Fatalf("get providers: %v", err)
	}
	defer resp.Body.Close()
	body := make([]byte, 0)
	buf := make([]byte, 4096)
	for {
		n, rerr := resp.Body.Read(buf)
		body = append(body, buf[:n]...)
		if rerr != nil {
			break
		}
	}
	models, err := parseOpencodeProviders(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(models) != 1 || models[0].ID != "opencode/big-pickle" || !models[0].IsDefault {
		t.Fatalf("models = %+v", models)
	}
}

func TestOpencodeBackend_Capabilities(t *testing.T) {
	c := opencodeBackend{}.Capabilities()
	if c.Compact || c.AskUserQuestion || c.Effort || c.Usage {
		t.Errorf("compact/ask/effort/usage should be off: %+v", c)
	}
	if !c.Resume || !c.Interrupt {
		t.Errorf("resume + interrupt should be on: %+v", c)
	}
	// Usage method reports unsupported (ok=false).
	if _, ok, _ := (opencodeBackend{}).Usage(context.Background(), nil, ""); ok {
		t.Error("Usage should report ok=false")
	}
}

func TestOpencodeServeArgs(t *testing.T) {
	c := &opencodeServerProcess{baseArgs: []string{"serve", "--hostname", "127.0.0.1"}}
	got := c.serveArgs(47999)
	want := []string{"serve", "--hostname", "127.0.0.1", "--port", "47999"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("serveArgs = %v, want %v", got, want)
	}
	// Empty base falls back to the documented default.
	c2 := &opencodeServerProcess{}
	if fmt.Sprint(c2.serveArgs(1)) != fmt.Sprint([]string{"serve", "--hostname", "127.0.0.1", "--port", "1"}) {
		t.Fatalf("default serveArgs = %v", c2.serveArgs(1))
	}
}

// waitFor polls cond until true or the deadline elapses.
func waitFor(t *testing.T, d time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.After(d)
	for {
		if cond() {
			return
		}
		select {
		case <-deadline:
			t.Fatal("waitFor: condition not met before deadline")
		case <-time.After(5 * time.Millisecond):
		}
	}
}
