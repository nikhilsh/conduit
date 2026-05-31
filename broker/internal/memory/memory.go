package memory

import (
	"bytes"
	"errors"
	"fmt"
	"html"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	Version = "v1"
	maxSize = 1 << 20
)

type Scope string

const (
	ScopeProject Scope = "project"
	ScopeSession Scope = "session"
)

type Paths struct {
	Root         string
	MemoryDir    string
	SessionsDir  string
	ProjectFile  string
	TemplateFile string
	StylesFile   string
	HandoffOut   string
}

type SessionData struct {
	SessionID      string
	WorktreePath   string
	Branch         string
	TaskID         string
	CurrentAgent   string
	CreatedAt      time.Time
	CheckpointAt   time.Time
	TaskBriefPath  string
	TaskSummary    string
	LastCompleted  string
	CurrentlyDoing string
	NextStep       string
	ScrollbackTail string
}

type CheckpointOptions struct {
	SessionData
	Reason string
}

type HandoffOptions struct {
	SessionID   string
	From        string
	To          string
	Reason      string
	HandoffPath string
}

type PromoteResult struct {
	SourceDecisionID string
	PromotedDecision string
}

type ValidationError struct {
	Problems []string
}

func (e *ValidationError) Error() string {
	return "memory validation failed: " + strings.Join(e.Problems, "; ")
}

var (
	errSessionNotFound = errors.New("session memory not found")
	errProjectNotFound = errors.New("project memory not found")

	htmlTagRe      = regexp.MustCompile(`(?is)<html\b([^>]*)>`)
	dataAttrRe     = regexp.MustCompile(`\b([a-z0-9-:]+)="([^"]*)"`)
	sectionOpenRe  = regexp.MustCompile(`(?is)<(header|section)\b[^>]*\bdata-section="([^"]+)"[^>]*>`)
	dataIDRe       = regexp.MustCompile(`\bdata-id="(d-\d+)"`)
	dataFillRe     = regexp.MustCompile(`\bdata-fill="([^"]+)"`)
	disallowedTag  = regexp.MustCompile(`(?is)<\s*(script|iframe|object|embed|form)\b`)
	eventAttrRe    = regexp.MustCompile(`(?i)\son[a-z0-9_-]+\s*=`)
	metaPairRe     = regexp.MustCompile(`(?is)<dt>\s*([^<]+?)\s*</dt>\s*<dd[^>]*>(.*?)</dd>`)
	liByIDTemplate = `(?is)<li\b[^>]*\bdata-id="%s"[^>]*>(.*?)</li>`
)

var requiredSections = map[Scope][]string{
	ScopeProject: {
		"meta",
		"north-star",
		"frozen-contracts",
		"decisions",
		"conventions",
		"open-questions",
		"promoted-from-sessions",
	},
	ScopeSession: {
		"meta",
		"task",
		"state",
		"decisions",
		"attempts",
		"open-questions",
		"env-snapshot",
		"handoff",
	},
}

var requiredMetaKeys = map[Scope][]string{
	ScopeProject: {"repo", "memory-format", "last-promoted"},
	ScopeSession: {"session", "worktree", "branch", "task", "current-agent", "created", "last-checkpoint"},
}

var allowedDataFills = map[Scope][]string{
	ScopeProject: {},
	ScopeSession: {
		"session-uuid",
		"worktree",
		"branch",
		"task-id",
		"agent",
		"created",
		"last-checkpoint",
		"task-brief-path",
		"task-summary",
		"last-completed",
		"now",
		"next",
		"scrollback-tail",
		"handoff-from",
		"handoff-to",
		"handoff-reason",
		"handoff-body",
	},
}

func DefaultPaths(root string) Paths {
	memoryDir := filepath.Join(root, ".conduit", "memory")
	return Paths{
		Root:         root,
		MemoryDir:    memoryDir,
		SessionsDir:  filepath.Join(memoryDir, "sessions"),
		ProjectFile:  filepath.Join(memoryDir, "index.html"),
		TemplateFile: filepath.Join(memoryDir, "session-template.html"),
		StylesFile:   filepath.Join(memoryDir, "memory.css"),
		HandoffOut:   filepath.Join(root, ".conduit", "HANDOFF-OUT.html"),
	}
}

func Init(root string) error {
	paths := DefaultPaths(root)
	if err := os.MkdirAll(paths.SessionsDir, 0o755); err != nil {
		return err
	}
	if err := ensureFile(paths.ProjectFile, defaultProjectHTML); err != nil {
		return err
	}
	if err := ensureFile(paths.TemplateFile, defaultSessionTemplateHTML); err != nil {
		return err
	}
	if err := ensureFile(paths.StylesFile, defaultStylesCSS); err != nil {
		return err
	}
	return nil
}

func ValidateDocument(doc string) error {
	var problems []string
	if len(doc) > maxSize {
		problems = append(problems, "file exceeds 1 MiB")
	}
	if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(doc)), "<!doctype html>") {
		problems = append(problems, "missing <!doctype html>")
	}
	if disallowedTag.MatchString(doc) {
		problems = append(problems, "contains disallowed element")
	}
	if eventAttrRe.MatchString(doc) {
		problems = append(problems, "contains disallowed event-handler attribute")
	}

	scope, version, sections, err := inspect(doc)
	if err != nil {
		problems = append(problems, err.Error())
	} else {
		if version != Version {
			problems = append(problems, fmt.Sprintf("unsupported memory version %q", version))
		}
		for _, name := range requiredSections[scope] {
			if _, ok := sections[name]; !ok {
				problems = append(problems, fmt.Sprintf("missing required section %q", name))
			}
		}
		if meta, ok := sections["meta"]; ok {
			for _, key := range requiredMetaKeys[scope] {
				if !strings.Contains(strings.ToLower(meta), "<dt>"+strings.ToLower(key)+"</dt>") {
					problems = append(problems, fmt.Sprintf("missing meta key %q", key))
				}
			}
		}
		allowed := allowedDataFills[scope]
		for _, match := range dataFillRe.FindAllStringSubmatch(doc, -1) {
			if !slices.Contains(allowed, match[1]) {
				problems = append(problems, fmt.Sprintf("unresolved data-fill %q", match[1]))
			}
		}
	}

	seen := map[string]struct{}{}
	for _, match := range dataIDRe.FindAllStringSubmatch(doc, -1) {
		if _, ok := seen[match[1]]; ok {
			problems = append(problems, fmt.Sprintf("duplicate decision data-id %q", match[1]))
			break
		}
		seen[match[1]] = struct{}{}
	}
	if len(problems) > 0 {
		return &ValidationError{Problems: problems}
	}
	return nil
}

func Render(root, sessionID string) (string, error) {
	doc, err := os.ReadFile(DefaultPaths(root).sessionFile(sessionID))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", errSessionNotFound
		}
		return "", err
	}
	if err := ValidateDocument(string(doc)); err != nil {
		return "", err
	}
	return string(doc), nil
}

func Checkpoint(root string, opts CheckpointOptions) (string, error) {
	if err := Init(root); err != nil {
		return "", err
	}
	if opts.SessionID == "" {
		return "", errors.New("checkpoint requires session id")
	}
	now := opts.CheckpointAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if opts.CreatedAt.IsZero() {
		opts.CreatedAt = now
	}
	paths := DefaultPaths(root)
	path := paths.sessionFile(opts.SessionID)
	current, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}

	var doc string
	if errors.Is(err, os.ErrNotExist) {
		doc, err = renderSessionDocument(opts.SessionData.withDefaults(now), opts.Reason)
		if err != nil {
			return "", err
		}
	} else {
		doc = string(current)
		if err := ValidateDocument(doc); err != nil {
			return "", err
		}
		values := readSessionValues(doc)
		values.updateFrom(opts.SessionData)
		values.CheckpointAt = now
		values.ScrollbackTail = opts.ScrollbackTail
		stateReason := opts.Reason
		doc = replaceSection(doc, "meta", buildSessionMeta(values))
		doc = replaceSection(doc, "task", buildTaskSection(values.TaskBriefPath, values.TaskSummary))
		doc = replaceSection(doc, "state", buildStateSection(values.LastCompleted, values.CurrentlyDoing, values.NextStep, stateReason))
		doc = replaceSection(doc, "env-snapshot", buildEnvSnapshotSection(values.ScrollbackTail))
	}
	if err := ValidateDocument(doc); err != nil {
		return "", err
	}
	if err := atomicWrite(path, []byte(doc)); err != nil {
		return "", err
	}
	return doc, nil
}

func Handoff(root string, opts HandoffOptions) (string, error) {
	if opts.SessionID == "" || opts.From == "" || opts.To == "" {
		return "", errors.New("handoff requires session, from, and to")
	}
	doc, err := Render(root, opts.SessionID)
	if err != nil {
		return "", err
	}
	handoffPath := opts.HandoffPath
	if handoffPath == "" {
		handoffPath = DefaultPaths(root).HandoffOut
	}
	raw, err := os.ReadFile(handoffPath)
	if err != nil {
		return "", err
	}
	if err := ValidateDocument(string(raw)); err != nil {
		return "", fmt.Errorf("handoff source: %w", err)
	}
	srcScope, _, sections, err := inspect(string(raw))
	if err != nil {
		return "", err
	}
	if srcScope != ScopeSession {
		return "", fmt.Errorf("handoff source must be session scope, got %s", srcScope)
	}
	handoff, ok := sections["handoff"]
	if !ok {
		return "", errors.New("handoff source missing handoff section")
	}
	body, err := extractDataFillInnerHTML(handoff, "handoff-body")
	if err != nil {
		return "", err
	}
	reason := opts.Reason
	if reason == "" {
		reason = strings.TrimSpace(extractLabeledText(handoff, "handoff-reason", "Reason:"))
	}
	merged := buildHandoffSection(opts.From, opts.To, reason, body, false)
	doc = replaceSection(doc, "handoff", merged)
	if err := ValidateDocument(doc); err != nil {
		return "", err
	}
	if err := atomicWrite(DefaultPaths(root).sessionFile(opts.SessionID), []byte(doc)); err != nil {
		return "", err
	}
	return doc, nil
}

func Promote(root, sessionID, decisionID string, promotedAt time.Time) (PromoteResult, error) {
	if sessionID == "" || decisionID == "" {
		return PromoteResult{}, errors.New("promote requires session and decision id")
	}
	if promotedAt.IsZero() {
		promotedAt = time.Now().UTC()
	}
	paths := DefaultPaths(root)
	project, err := os.ReadFile(paths.ProjectFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return PromoteResult{}, errProjectNotFound
		}
		return PromoteResult{}, err
	}
	session, err := os.ReadFile(paths.sessionFile(sessionID))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return PromoteResult{}, errSessionNotFound
		}
		return PromoteResult{}, err
	}
	projectDoc := string(project)
	sessionDoc := string(session)
	if err := ValidateDocument(projectDoc); err != nil {
		return PromoteResult{}, err
	}
	if err := ValidateDocument(sessionDoc); err != nil {
		return PromoteResult{}, err
	}
	projectDecisionID := nextDecisionID(projectDoc)
	re := regexp.MustCompile(fmt.Sprintf(liByIDTemplate, regexp.QuoteMeta(decisionID)))
	match := re.FindStringSubmatch(sessionDoc)
	if match == nil {
		return PromoteResult{}, fmt.Errorf("decision %q not found", decisionID)
	}
	decisionInner := strings.TrimSpace(match[1])
	projectDecision := fmt.Sprintf(`<li data-id="%s" data-source-session="%s" data-source-decision="%s">%s</li>`, projectDecisionID, escapeAttr(sessionID), escapeAttr(decisionID), decisionInner)
	projectDoc, err = appendListItem(projectDoc, "decisions", projectDecision)
	if err != nil {
		return PromoteResult{}, err
	}
	note := fmt.Sprintf(`<li data-source-session="%s" data-source-decision="%s"><code>%s</code> promoted from session <code>%s</code>: %s</li>`, escapeAttr(sessionID), escapeAttr(decisionID), projectDecisionID, html.EscapeString(sessionID), stripTags(decisionInner))
	projectDoc, err = appendListItem(projectDoc, "promoted-from-sessions", note)
	if err != nil {
		return PromoteResult{}, err
	}
	projectDoc = replaceSection(projectDoc, "meta", buildProjectMetaSection(promotedAt))
	if err := ValidateDocument(projectDoc); err != nil {
		return PromoteResult{}, err
	}
	if err := atomicWrite(paths.ProjectFile, []byte(projectDoc)); err != nil {
		return PromoteResult{}, err
	}
	return PromoteResult{SourceDecisionID: decisionID, PromotedDecision: projectDecisionID}, nil
}

func Show(root, sessionID string) (string, error) {
	path := DefaultPaths(root).ProjectFile
	if sessionID != "" {
		path = DefaultPaths(root).sessionFile(sessionID)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) && sessionID != "" {
			return "", errSessionNotFound
		}
		return "", err
	}
	doc := string(raw)
	if err := ValidateDocument(doc); err != nil {
		return "", err
	}
	_, _, sections, err := inspect(doc)
	if err != nil {
		return "", err
	}
	order := []string{"meta", "north-star", "frozen-contracts", "task", "state", "decisions", "attempts", "conventions", "open-questions", "env-snapshot", "handoff", "promoted-from-sessions"}
	var out []string
	for _, name := range order {
		section, ok := sections[name]
		if !ok {
			continue
		}
		title := strings.ToUpper(strings.ReplaceAll(name, "-", " "))
		out = append(out, title)
		lines := sectionToLines(section)
		if len(lines) == 0 {
			out = append(out, "(empty)")
			continue
		}
		out = append(out, lines...)
		out = append(out, "")
	}
	return strings.TrimSpace(strings.Join(out, "\n")) + "\n", nil
}

func renderSessionDocument(data SessionData, checkpointReason string) (string, error) {
	if data.SessionID == "" || data.WorktreePath == "" || data.Branch == "" || data.TaskID == "" || data.CurrentAgent == "" || data.TaskBriefPath == "" || data.TaskSummary == "" {
		return "", errors.New("render session requires session metadata")
	}
	return fmt.Sprintf(`<!doctype html>
<html lang="en" data-conduit-memory="%s" data-scope="session">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>conduit session memory</title>
  <link rel="stylesheet" href="../memory.css">
</head>
<body>
%s
%s
%s
  <section data-section="decisions">
    <h2>Decisions made this session</h2>
    <ol></ol>
  </section>

  <section data-section="attempts">
    <h2>Things I tried that did not work</h2>
    <ul></ul>
  </section>

  <section data-section="open-questions">
    <h2>Open questions for the next agent</h2>
    <ul></ul>
  </section>

%s

%s
</body>
</html>
`, Version, buildSessionMeta(data), buildTaskSection(data.TaskBriefPath, data.TaskSummary), buildStateSection(data.LastCompleted, data.CurrentlyDoing, data.NextStep, checkpointReason), buildEnvSnapshotSection(data.ScrollbackTail), buildHandoffSection("—", "—", "—", "", true)), nil
}

func buildSessionMeta(data SessionData) string {
	created := data.CreatedAt.UTC().Format(time.RFC3339)
	checkpoint := data.CheckpointAt.UTC().Format(time.RFC3339)
	return fmt.Sprintf(`  <header data-section="meta">
    <dl>
      <dt>session</dt><dd><code data-fill="session-uuid">%s</code></dd>
      <dt>worktree</dt><dd><code data-fill="worktree">%s</code></dd>
      <dt>branch</dt><dd><code data-fill="branch">%s</code></dd>
      <dt>task</dt><dd data-fill="task-id">%s</dd>
      <dt>current-agent</dt><dd data-fill="agent">%s</dd>
      <dt>created</dt><dd><time data-fill="created" datetime="%s">%s</time></dd>
      <dt>last-checkpoint</dt><dd><time data-fill="last-checkpoint" datetime="%s">%s</time></dd>
    </dl>
  </header>`,
		html.EscapeString(data.SessionID),
		html.EscapeString(data.WorktreePath),
		html.EscapeString(data.Branch),
		html.EscapeString(data.TaskID),
		html.EscapeString(data.CurrentAgent),
		created,
		created,
		checkpoint,
		checkpoint,
	)
}

func buildProjectMetaSection(ts time.Time) string {
	label := "never"
	attr := ""
	if !ts.IsZero() {
		attr = ts.UTC().Format(time.RFC3339)
		label = attr
	}
	return fmt.Sprintf(`  <header data-section="meta">
    <dl>
      <dt>scope</dt><dd>project</dd>
      <dt>repo</dt><dd><code>git@github.com:nikhilsh/conduit.git</code></dd>
      <dt>memory-format</dt><dd>v1 (see <code>docs/MEMORY-FORMAT.md</code>)</dd>
      <dt>last-promoted</dt><dd><time datetime="%s">%s</time></dd>
    </dl>
  </header>`, attr, label)
}

func buildTaskSection(taskBriefPath, taskSummary string) string {
	return fmt.Sprintf(`  <section data-section="task">
    <h2>Current task</h2>
    <p>See <code data-fill="task-brief-path">%s</code> for the full brief.</p>
    <p data-fill="task-summary">%s</p>
  </section>`, html.EscapeString(taskBriefPath), html.EscapeString(taskSummary))
}

func buildStateSection(lastCompleted, now, next, reason string) string {
	lines := []string{
		`  <section data-section="state">`,
		`    <h2>Where I am</h2>`,
		fmt.Sprintf(`    <p><strong>Last completed:</strong> <span data-fill="last-completed">%s</span></p>`, html.EscapeString(defaultDash(lastCompleted))),
		fmt.Sprintf(`    <p><strong>Currently working on:</strong> <span data-fill="now">%s</span></p>`, html.EscapeString(defaultDash(now))),
		fmt.Sprintf(`    <p><strong>Next step:</strong> <span data-fill="next">%s</span></p>`, html.EscapeString(defaultDash(next))),
	}
	if reason != "" {
		lines = append(lines, fmt.Sprintf(`    <p><strong>Checkpoint note:</strong> %s</p>`, html.EscapeString(reason)))
	}
	lines = append(lines, `  </section>`)
	return strings.Join(lines, "\n")
}

func buildEnvSnapshotSection(tail string) string {
	return fmt.Sprintf(`  <section data-section="env-snapshot">
    <h2>Environment snapshot</h2>
    <pre><code data-fill="scrollback-tail">%s</code></pre>
  </section>`, html.EscapeString(tail))
}

func buildHandoffSection(from, to, reason, body string, hidden bool) string {
	hiddenAttr := ""
	if hidden {
		hiddenAttr = " hidden"
	}
	bodyContent := strings.TrimSpace(body)
	if bodyContent == "" {
		bodyContent = ""
	}
	return fmt.Sprintf(`  <section data-section="handoff"%s>
    <h2>Handoff brief</h2>
    <p data-fill="handoff-from">From: %s</p>
    <p data-fill="handoff-to">To: %s</p>
    <p data-fill="handoff-reason">Reason: %s</p>
    <div data-fill="handoff-body">%s</div>
  </section>`, hiddenAttr, html.EscapeString(from), html.EscapeString(to), html.EscapeString(reason), bodyContent)
}

func inspect(doc string) (Scope, string, map[string]string, error) {
	match := htmlTagRe.FindStringSubmatch(doc)
	if match == nil {
		return "", "", nil, errors.New("missing <html> root")
	}
	attrs := map[string]string{}
	for _, attr := range dataAttrRe.FindAllStringSubmatch(match[1], -1) {
		attrs[strings.ToLower(attr[1])] = attr[2]
	}
	scope := Scope(attrs["data-scope"])
	if scope != ScopeProject && scope != ScopeSession {
		return "", "", nil, fmt.Errorf("invalid data-scope %q", attrs["data-scope"])
	}
	version := attrs["data-conduit-memory"]
	if version == "" {
		return "", "", nil, errors.New("missing data-conduit-memory attribute")
	}

	sections := map[string]string{}
	matches := sectionOpenRe.FindAllStringSubmatchIndex(doc, -1)
	for _, m := range matches {
		tagName := doc[m[2]:m[3]]
		name := doc[m[4]:m[5]]
		start := m[0]
		afterOpen := m[1]
		closeTag := "</" + tagName + ">"
		endRel := strings.Index(strings.ToLower(doc[afterOpen:]), strings.ToLower(closeTag))
		if endRel < 0 {
			return "", "", nil, fmt.Errorf("section %q missing closing tag", name)
		}
		end := afterOpen + endRel + len(closeTag)
		sections[name] = doc[start:end]
	}
	return scope, version, sections, nil
}

func replaceSection(doc, name, replacement string) string {
	scope, _, sections, err := inspect(doc)
	if err != nil {
		return doc
	}
	section, ok := sections[name]
	if !ok {
		return doc
	}
	_ = scope
	return strings.Replace(doc, section, replacement, 1)
}

func sectionToLines(section string) []string {
	text := stripTags(section)
	rawLines := strings.Split(text, "\n")
	var out []string
	for _, line := range rawLines {
		line = strings.TrimSpace(strings.ReplaceAll(line, "\u00a0", " "))
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	return out
}

func stripTags(s string) string {
	replacer := strings.NewReplacer(
		"</p>", "\n",
		"</li>", "\n",
		"</dt>", ": ",
		"</dd>", "\n",
		"</h2>", "\n",
		"<br>", "\n",
		"<br/>", "\n",
		"<br />", "\n",
	)
	s = replacer.Replace(s)
	var buf bytes.Buffer
	inTag := false
	for _, r := range s {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
		case !inTag:
			buf.WriteRune(r)
		}
	}
	return html.UnescapeString(buf.String())
}

func readSessionValues(doc string) SessionData {
	sections := mustSections(doc)
	meta := readMetaSection(sections["meta"])
	state := sections["state"]
	task := sections["task"]
	values := SessionData{
		SessionID:      meta["session"],
		WorktreePath:   meta["worktree"],
		Branch:         meta["branch"],
		TaskID:         meta["task"],
		CurrentAgent:   meta["current-agent"],
		TaskBriefPath:  extractDataFillText(task, "task-brief-path"),
		TaskSummary:    extractDataFillText(task, "task-summary"),
		LastCompleted:  extractDataFillText(state, "last-completed"),
		CurrentlyDoing: extractDataFillText(state, "now"),
		NextStep:       extractDataFillText(state, "next"),
		ScrollbackTail: extractDataFillText(sections["env-snapshot"], "scrollback-tail"),
	}
	if created, err := time.Parse(time.RFC3339, meta["created"]); err == nil {
		values.CreatedAt = created
	}
	if checkpoint, err := time.Parse(time.RFC3339, meta["last-checkpoint"]); err == nil {
		values.CheckpointAt = checkpoint
	}
	if values.CreatedAt.IsZero() {
		values.CreatedAt = values.CheckpointAt
	}
	return values
}

func readMetaSection(section string) map[string]string {
	values := map[string]string{}
	for _, match := range metaPairRe.FindAllStringSubmatch(section, -1) {
		key := strings.TrimSpace(strings.ToLower(match[1]))
		values[key] = stripTags(match[2])
	}
	return values
}

func mustSections(doc string) map[string]string {
	_, _, sections, _ := inspect(doc)
	return sections
}

func extractDataFillText(section, fill string) string {
	re := regexp.MustCompile(fmt.Sprintf(`(?is)<[a-z0-9]+\b[^>]*\bdata-fill="%s"[^>]*>(.*?)</[a-z0-9]+>`, regexp.QuoteMeta(fill)))
	match := re.FindStringSubmatch(section)
	if match == nil {
		return ""
	}
	return strings.TrimSpace(stripTags(match[1]))
}

func extractDataFillInnerHTML(section, fill string) (string, error) {
	re := regexp.MustCompile(fmt.Sprintf(`(?is)<[a-z0-9]+\b[^>]*\bdata-fill="%s"[^>]*>(.*?)</[a-z0-9]+>`, regexp.QuoteMeta(fill)))
	match := re.FindStringSubmatch(section)
	if match == nil {
		return "", fmt.Errorf("missing data-fill %q", fill)
	}
	return strings.TrimSpace(match[1]), nil
}

func extractLabeledText(section, fill, prefix string) string {
	text := extractDataFillText(section, fill)
	return strings.TrimSpace(strings.TrimPrefix(text, prefix))
}

func appendListItem(doc, sectionName, li string) (string, error) {
	section := mustSections(doc)[sectionName]
	if section == "" {
		return "", fmt.Errorf("section %q missing", sectionName)
	}
	switch {
	case strings.Contains(section, "<ol></ol>"):
		section = strings.Replace(section, "<ol></ol>", "<ol>\n      "+li+"\n    </ol>", 1)
	case strings.Contains(section, "<ul></ul>"):
		section = strings.Replace(section, "<ul></ul>", "<ul>\n      "+li+"\n    </ul>", 1)
	case strings.Contains(section, "</ol>"):
		section = strings.Replace(section, "</ol>", "      "+li+"\n    </ol>", 1)
	case strings.Contains(section, "</ul>"):
		section = strings.Replace(section, "</ul>", "      "+li+"\n    </ul>", 1)
	default:
		return "", fmt.Errorf("section %q has no list", sectionName)
	}
	return replaceSection(doc, sectionName, section), nil
}

func nextDecisionID(doc string) string {
	max := 0
	for _, match := range dataIDRe.FindAllStringSubmatch(doc, -1) {
		n, err := strconv.Atoi(strings.TrimPrefix(match[1], "d-"))
		if err == nil && n > max {
			max = n
		}
	}
	return fmt.Sprintf("d-%03d", max+1)
}

func atomicWrite(path string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".memory-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func ensureFile(path, body string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicWrite(path, []byte(body))
}

func escapeAttr(s string) string {
	replacer := strings.NewReplacer(`&`, "&amp;", `"`, "&quot;", `<`, "&lt;", `>`, "&gt;")
	return replacer.Replace(s)
}

func defaultDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return s
}

func (p Paths) sessionFile(sessionID string) string {
	return filepath.Join(p.SessionsDir, sessionID+".html")
}

func (s SessionData) withDefaults(now time.Time) SessionData {
	if s.CreatedAt.IsZero() {
		s.CreatedAt = now
	}
	if s.CheckpointAt.IsZero() {
		s.CheckpointAt = now
	}
	return s
}

func (s *SessionData) updateFrom(next SessionData) {
	if next.SessionID != "" {
		s.SessionID = next.SessionID
	}
	if next.WorktreePath != "" {
		s.WorktreePath = next.WorktreePath
	}
	if next.Branch != "" {
		s.Branch = next.Branch
	}
	if next.TaskID != "" {
		s.TaskID = next.TaskID
	}
	if next.CurrentAgent != "" {
		s.CurrentAgent = next.CurrentAgent
	}
	if !next.CreatedAt.IsZero() {
		s.CreatedAt = next.CreatedAt
	}
	if !next.CheckpointAt.IsZero() {
		s.CheckpointAt = next.CheckpointAt
	}
	if next.TaskBriefPath != "" {
		s.TaskBriefPath = next.TaskBriefPath
	}
	if next.TaskSummary != "" {
		s.TaskSummary = next.TaskSummary
	}
	if next.LastCompleted != "" {
		s.LastCompleted = next.LastCompleted
	}
	if next.CurrentlyDoing != "" {
		s.CurrentlyDoing = next.CurrentlyDoing
	}
	if next.NextStep != "" {
		s.NextStep = next.NextStep
	}
	if next.ScrollbackTail != "" {
		s.ScrollbackTail = next.ScrollbackTail
	}
}

const defaultProjectHTML = `<!doctype html>
<html lang="en" data-conduit-memory="v1" data-scope="project">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>conduit project memory</title>
  <link rel="stylesheet" href="memory.css">
</head>
<body>
  <header data-section="meta">
    <dl>
      <dt>scope</dt><dd>project</dd>
      <dt>repo</dt><dd><code>git@github.com:nikhilsh/conduit.git</code></dd>
      <dt>memory-format</dt><dd>v1 (see <code>docs/MEMORY-FORMAT.md</code>)</dd>
      <dt>last-promoted</dt><dd><time datetime="">never</time></dd>
    </dl>
  </header>

  <section data-section="north-star">
    <h2>North star</h2>
    <p>A phone-first AI coding harness.</p>
  </section>

  <section data-section="frozen-contracts">
    <h2>Frozen contracts</h2>
    <ol>
      <li><code>docs/WEBSOCKET-PROTOCOL.md</code></li>
      <li><code>docs/AGENT-ADAPTERS.md</code></li>
      <li><code>docs/MEMORY-FORMAT.md</code></li>
      <li><code>docs/SESSION-LIFECYCLE.md</code></li>
    </ol>
  </section>

  <section data-section="decisions">
    <h2>Project-wide decisions</h2>
    <ol></ol>
  </section>

  <section data-section="conventions">
    <h2>Conventions</h2>
    <ul></ul>
  </section>

  <section data-section="open-questions">
    <h2>Open project-wide questions</h2>
    <ul></ul>
  </section>

  <section data-section="promoted-from-sessions">
    <h2>Insights promoted from sessions</h2>
    <ol></ol>
  </section>
</body>
</html>
`

const defaultSessionTemplateHTML = `<!doctype html>
<html lang="en" data-conduit-memory="v1" data-scope="session">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>conduit session memory</title>
  <link rel="stylesheet" href="../memory.css">
</head>
<body>
  <header data-section="meta">
    <dl>
      <dt>session</dt><dd><code data-fill="session-uuid">{{SESSION_UUID}}</code></dd>
      <dt>worktree</dt><dd><code data-fill="worktree">{{WORKTREE_PATH}}</code></dd>
      <dt>branch</dt><dd><code data-fill="branch">{{BRANCH}}</code></dd>
      <dt>task</dt><dd data-fill="task-id">{{TASK_ID}}</dd>
      <dt>current-agent</dt><dd data-fill="agent">{{AGENT_NAME}}</dd>
      <dt>created</dt><dd><time data-fill="created" datetime="{{CREATED_ISO}}">{{CREATED_ISO}}</time></dd>
      <dt>last-checkpoint</dt><dd><time data-fill="last-checkpoint" datetime="{{CHECKPOINT_ISO}}">{{CHECKPOINT_ISO}}</time></dd>
    </dl>
  </header>

  <section data-section="task">
    <h2>Current task</h2>
    <p>See <code data-fill="task-brief-path">{{TASK_BRIEF_PATH}}</code> for the full brief.</p>
    <p data-fill="task-summary">{{TASK_SUMMARY}}</p>
  </section>

  <section data-section="state">
    <h2>Where I am</h2>
    <p><strong>Last completed:</strong> <span data-fill="last-completed">—</span></p>
    <p><strong>Currently working on:</strong> <span data-fill="now">—</span></p>
    <p><strong>Next step:</strong> <span data-fill="next">—</span></p>
  </section>

  <section data-section="decisions">
    <h2>Decisions made this session</h2>
    <ol></ol>
  </section>

  <section data-section="attempts">
    <h2>Things I tried that did not work</h2>
    <ul></ul>
  </section>

  <section data-section="open-questions">
    <h2>Open questions for the next agent</h2>
    <ul></ul>
  </section>

  <section data-section="env-snapshot">
    <h2>Environment snapshot</h2>
    <pre><code data-fill="scrollback-tail">(harness fills the last N lines of PTY scrollback here on checkpoint)</code></pre>
  </section>

  <section data-section="handoff" hidden>
    <h2>Handoff brief</h2>
    <p data-fill="handoff-from">From: —</p>
    <p data-fill="handoff-to">To: —</p>
    <p data-fill="handoff-reason">Reason: —</p>
    <div data-fill="handoff-body"></div>
  </section>
</body>
</html>
`

const defaultStylesCSS = `:root {
  color-scheme: light dark;
  --bg: #fafafa;
  --fg: #1c1c1e;
  --muted: #6b7280;
  --accent: #d97706;
  --code-bg: #f3f4f6;
  --border: #e5e7eb;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0b0b0d;
    --fg: #e5e7eb;
    --muted: #9ca3af;
    --accent: #f59e0b;
    --code-bg: #1f2937;
    --border: #1f2937;
  }
}

html, body {
  margin: 0;
  padding: 0;
  background: var(--bg);
  color: var(--fg);
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  -webkit-text-size-adjust: 100%;
}

body { padding: 1.25rem; max-width: 56rem; margin: 0 auto; }
header[data-section="meta"] {
  padding-bottom: 1rem;
  border-bottom: 1px solid var(--border);
  margin-bottom: 1.5rem;
}

header[data-section="meta"] dl {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: 0.25rem 1rem;
  margin: 0;
}

header[data-section="meta"] dt {
  color: var(--muted);
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

header[data-section="meta"] dd {
  margin: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.9rem;
}

section {
  margin-block: 1.75rem;
}

section > h2 {
  font-size: 1rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--accent);
  border-bottom: 1px solid var(--border);
  padding-bottom: 0.35rem;
  margin: 0 0 0.75rem 0;
}

section[hidden] { display: none; }
code, pre {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  background: var(--code-bg);
  border-radius: 6px;
}

code { padding: 0.1rem 0.35rem; font-size: 0.88em; }
pre { padding: 0.85rem; overflow-x: auto; font-size: 0.85em; line-height: 1.45; }
pre code { padding: 0; background: transparent; }
ul, ol { padding-left: 1.4rem; }
li { margin-block: 0.3rem; }
time { color: var(--muted); }
`
