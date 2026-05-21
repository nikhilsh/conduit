package session

import (
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// chatScraper turns raw PTY bytes from an agent back into structured
// chat events for the iOS / Android Chat tab. Tier 1 strategy: when
// the user sends a chat message we set `awaiting`, accumulate
// printable bytes through ansiStripper, and once the PTY has been
// idle for ~700ms we emit a single `view_event { view: "chat",
// event: { role: "assistant", ... } }` frame to text subscribers.
//
// The scraper is deliberately not trying to be a TUI parser. Tool
// calls, reasoning blocks, streaming deltas, and todo lists are all
// rolled into one assistant message. Tier 2 will split them.
type chatScraper struct {
	publish func(payload []byte)

	idleAfter time.Duration
	maxTurn   time.Duration
	now       func() time.Time // injectable for tests

	awaiting atomic.Bool

	mu          sync.Mutex
	stripper    ansiStripper
	buf         strings.Builder
	lastByte    time.Time
	turnStarted time.Time
	lastUser    string // for echo suppression

	tickerStop chan struct{}
	stopOnce   sync.Once
}

// newChatScraper builds a scraper with sensible defaults; environment
// variables override.
func newChatScraper(publish func([]byte)) *chatScraper {
	return &chatScraper{
		publish:    publish,
		idleAfter:  durationFromEnv("KITTY_CHAT_IDLE_MS", 700*time.Millisecond),
		maxTurn:    durationFromEnv("KITTY_CHAT_TURN_MAX_MS", 30*time.Second),
		now:        func() time.Time { return time.Now().UTC() },
		tickerStop: make(chan struct{}),
	}
}

// markUserSent is called by the chat handler immediately before the
// user's message is written into the PTY. It primes the scraper to
// capture the agent's reply.
func (c *chatScraper) markUserSent(msg string) {
	c.mu.Lock()
	c.buf.Reset()
	c.stripper = ansiStripper{}
	c.lastByte = c.now()
	c.turnStarted = c.lastByte
	c.lastUser = strings.TrimSpace(msg)
	c.mu.Unlock()
	c.awaiting.Store(true)
}

// feed consumes a chunk of PTY output. When the scraper is not
// awaiting a reply this is a no-op and adds essentially zero
// overhead to the drain hot path.
func (c *chatScraper) feed(chunk []byte) {
	if !c.awaiting.Load() {
		return
	}
	c.mu.Lock()
	visible := c.stripper.Write(chunk)
	if len(visible) > 0 {
		c.buf.Write(visible)
	}
	c.lastByte = c.now()
	c.mu.Unlock()
}

// run drives the idle timer. Exits when stop() is called or when the
// done channel closes (session shutdown).
func (c *chatScraper) run(done <-chan struct{}) {
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			c.tick()
		case <-c.tickerStop:
			return
		case <-done:
			return
		}
	}
}

func (c *chatScraper) stop() {
	c.stopOnce.Do(func() { close(c.tickerStop) })
}

// tick checks the idle threshold and the per-turn hard ceiling.
func (c *chatScraper) tick() {
	if !c.awaiting.Load() {
		return
	}
	c.mu.Lock()
	now := c.now()
	idle := now.Sub(c.lastByte)
	overall := now.Sub(c.turnStarted)
	bufLen := c.buf.Len()
	shouldFlush := bufLen > 0 && (idle >= c.idleAfter || overall >= c.maxTurn)
	c.mu.Unlock()
	if shouldFlush {
		c.flush()
	}
}

// flush builds the chat_event JSON and ships it via publish. Returns
// without doing anything if there is nothing meaningful to send.
func (c *chatScraper) flush() {
	c.mu.Lock()
	content := postClean(c.buf.String())
	last := c.lastUser
	c.buf.Reset()
	c.stripper = ansiStripper{}
	ts := c.now().Format(time.RFC3339Nano)
	c.mu.Unlock()

	c.awaiting.Store(false)
	if content == "" {
		return
	}
	// Echo suppression: agents redraw the user's own input bar
	// containing the just-sent text. Don't ship that back as an
	// "assistant" reply.
	if last != "" && strings.TrimSpace(content) == last {
		return
	}
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "chat",
		"event": map[string]any{
			"role":    "assistant",
			"content": content,
			"ts":      ts,
			"files":   []any{},
		},
	})
	if err != nil {
		return
	}
	c.publish(payload)
}

// postClean cleans up the captured text before it ships:
// - trim trailing whitespace
// - collapse runs of 3+ newlines to two (TUIs over-pad)
// - drop lines that are only border / box-drawing glyphs
func postClean(s string) string {
	if s == "" {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	lines := strings.Split(s, "\n")
	blankRun := 0
	for _, line := range lines {
		trimmed := strings.TrimRight(line, " \t")
		if isBorderOnly(trimmed) {
			continue
		}
		if strings.TrimSpace(trimmed) == "" {
			blankRun++
			if blankRun >= 2 {
				continue
			}
		} else {
			blankRun = 0
		}
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(trimmed)
	}
	return strings.TrimSpace(b.String())
}

// isBorderOnly reports whether the line is composed exclusively of
// box-drawing characters and whitespace. We use this to drop the
// frames TUIs (notably Claude) draw around their input prompt.
func isBorderOnly(s string) bool {
	if strings.TrimSpace(s) == "" {
		return false
	}
	for _, r := range s {
		if r == ' ' || r == '\t' {
			continue
		}
		if !isBorderRune(r) {
			return false
		}
	}
	return true
}

func isBorderRune(r rune) bool {
	// U+2500..U+257F are Box Drawing; U+2580..U+259F are Block
	// Elements (used for shaded bars). Catch both.
	if r >= 0x2500 && r <= 0x259F {
		return true
	}
	// ASCII pipe/dash glyphs that some agents fall back to.
	switch r {
	case '─', '│', '╭', '╮', '╯', '╰', '┃', '━':
		return true
	}
	return false
}
