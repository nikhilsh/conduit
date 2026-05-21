package session

import (
	"encoding/json"
	"sync"
	"testing"
	"time"
)

// captureScraper builds a chatScraper with deterministic time and a
// recording publisher. Callers drive `clock` forward and call tick()
// manually so tests don't depend on real wall-clock idleness.
func captureScraper() (*chatScraper, *fakeClock, *publishRecorder) {
	rec := &publishRecorder{}
	clock := newFakeClock()
	c := &chatScraper{
		publish:    rec.publish,
		idleAfter:  700 * time.Millisecond,
		maxTurn:    30 * time.Second,
		now:        clock.Now,
		tickerStop: make(chan struct{}),
	}
	return c, clock, rec
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC)}
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

type publishRecorder struct {
	mu     sync.Mutex
	frames [][]byte
}

func (p *publishRecorder) publish(payload []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()
	cp := make([]byte, len(payload))
	copy(cp, payload)
	p.frames = append(p.frames, cp)
}

func (p *publishRecorder) snapshot() [][]byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([][]byte, len(p.frames))
	copy(out, p.frames)
	return out
}

type chatFrame struct {
	Type  string `json:"type"`
	View  string `json:"view"`
	Event struct {
		Role    string `json:"role"`
		Content string `json:"content"`
		Ts      string `json:"ts"`
	} `json:"event"`
}

func decodeFrame(t *testing.T, raw []byte) chatFrame {
	t.Helper()
	var f chatFrame
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode frame: %v\nraw: %s", err, raw)
	}
	return f
}

func TestScraperPlainText(t *testing.T) {
	c, clock, rec := captureScraper()
	c.markUserSent("hi")
	c.feed([]byte("Hello, world!\n"))
	clock.Advance(800 * time.Millisecond)
	c.tick()
	frames := rec.snapshot()
	if len(frames) != 1 {
		t.Fatalf("want 1 frame, got %d", len(frames))
	}
	f := decodeFrame(t, frames[0])
	if f.Type != "view_event" || f.View != "chat" || f.Event.Role != "assistant" {
		t.Errorf("envelope wrong: %+v", f)
	}
	if f.Event.Content != "Hello, world!" {
		t.Errorf("content = %q", f.Event.Content)
	}
}

func TestScraperStripsCSI(t *testing.T) {
	c, clock, rec := captureScraper()
	c.markUserSent("color me")
	c.feed([]byte("\x1b[31mred answer\x1b[0m here"))
	clock.Advance(800 * time.Millisecond)
	c.tick()
	frames := rec.snapshot()
	if len(frames) != 1 {
		t.Fatalf("want 1 frame, got %d", len(frames))
	}
	f := decodeFrame(t, frames[0])
	if f.Event.Content != "red answer here" {
		t.Errorf("content = %q", f.Event.Content)
	}
}

func TestScraperEchoSuppression(t *testing.T) {
	c, clock, rec := captureScraper()
	c.markUserSent("ping?")
	// Some agents redraw the user's input bar showing their last
	// message. We must not ship that back as an "assistant" reply.
	c.feed([]byte("  ping?  \n"))
	clock.Advance(800 * time.Millisecond)
	c.tick()
	if frames := rec.snapshot(); len(frames) != 0 {
		t.Errorf("expected echo to be suppressed, got %d frames", len(frames))
	}
}

func TestScraperIgnoresWhenNotAwaiting(t *testing.T) {
	c, clock, rec := captureScraper()
	// No markUserSent → idle bytes should not produce events.
	c.feed([]byte("some background spinner output"))
	clock.Advance(2 * time.Second)
	c.tick()
	if frames := rec.snapshot(); len(frames) != 0 {
		t.Errorf("expected no frames while !awaiting, got %d", len(frames))
	}
}

func TestScraperSplitParagraphs(t *testing.T) {
	c, clock, rec := captureScraper()
	c.markUserSent("two pls")
	c.feed([]byte("first paragraph"))
	// Idle gap longer than threshold → flush.
	clock.Advance(800 * time.Millisecond)
	c.tick()
	// Next turn the user would normally trigger; here we test that
	// post-idle the scraper has stopped awaiting and a second batch
	// of bytes without a new markUserSent doesn't produce another
	// frame.
	c.feed([]byte("second paragraph"))
	clock.Advance(2 * time.Second)
	c.tick()
	frames := rec.snapshot()
	if len(frames) != 1 {
		t.Fatalf("want 1 frame, got %d", len(frames))
	}
	if f := decodeFrame(t, frames[0]); f.Event.Content != "first paragraph" {
		t.Errorf("content = %q", f.Event.Content)
	}
}

func TestScraperMaxTurnCeiling(t *testing.T) {
	c, clock, rec := captureScraper()
	c.maxTurn = 500 * time.Millisecond
	c.markUserSent("long?")
	// Feed once, then keep bumping lastByte BEFORE idle threshold
	// triggers, but past maxTurn → still flush.
	c.feed([]byte("opening"))
	clock.Advance(200 * time.Millisecond)
	c.feed([]byte(" middle"))
	clock.Advance(200 * time.Millisecond)
	c.feed([]byte(" closing"))
	clock.Advance(200 * time.Millisecond)
	c.tick()
	frames := rec.snapshot()
	if len(frames) != 1 {
		t.Fatalf("want 1 frame from maxTurn ceiling, got %d", len(frames))
	}
	if f := decodeFrame(t, frames[0]); f.Event.Content != "opening middle closing" {
		t.Errorf("content = %q", f.Event.Content)
	}
}

func TestScraperDropsBorderLines(t *testing.T) {
	c, clock, rec := captureScraper()
	c.markUserSent("box")
	// Claude-style bordered prompt around real prose.
	c.feed([]byte("╭──────────╮\n│ ignored  │\n╰──────────╯\nreal answer\n"))
	clock.Advance(800 * time.Millisecond)
	c.tick()
	frames := rec.snapshot()
	if len(frames) != 1 {
		t.Fatalf("want 1 frame, got %d", len(frames))
	}
	if f := decodeFrame(t, frames[0]); f.Event.Content != "│ ignored  │\nreal answer" &&
		f.Event.Content != "real answer" {
		// Mid-bordered lines that are not pure border get kept (no
		// false drops); pure border lines are stripped.
		t.Errorf("content = %q", f.Event.Content)
	}
}

func TestScraperEmptyAfterClean(t *testing.T) {
	c, clock, rec := captureScraper()
	c.markUserSent("noop")
	// Only control bytes → nothing visible.
	c.feed([]byte("\x1b[2J\x1b[H\x07"))
	clock.Advance(800 * time.Millisecond)
	c.tick()
	if frames := rec.snapshot(); len(frames) != 0 {
		t.Errorf("expected 0 frames for empty content, got %d", len(frames))
	}
}
