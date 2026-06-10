package session

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
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
