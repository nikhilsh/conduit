package session

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// codexGen is the aiGenProvider backed by a one-shot `codex exec` run. It
// powers AI session titles + quick replies for codex sessions, the codex twin
// of anthropicGen. Each Complete is a fresh, throwaway `codex exec --json`
// invocation (no thread, no resume): the prompt goes on the argv, the final
// agent message is parsed out of the JSONL stdout via the same
// parseCodexStreamLine the chat backend uses.
//
// Best-effort by contract: any spawn/parse failure returns an error the
// caller treats as "emit nothing". We never touch the live session's codex
// thread or its credentials beyond reading them implicitly through the CLI.
type codexGen struct {
	binary string // adapter.Command[0], e.g. "codex"
	// model is the small model slug to pass via --model (smallest from the
	// discovered catalog). "" omits --model so codex picks its own default.
	model string
}

// codexGenArgv builds the argv for one one-shot generation turn. It mirrors
// the first-turn shape from codexTurnArgv (exec --json --skip-git-repo-check)
// but pins reasoning effort low and routes the prompt on the argv. No
// thread/resume: each call is independent. `--model` is included only when a
// small model was resolved from the catalog. Pure, for unit-testing.
func codexGenArgv(binary, model, prompt string) []string {
	argv := []string{binary, "exec", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=low"}
	if strings.TrimSpace(model) != "" {
		argv = append(argv, "--model", model)
	}
	return append(argv, prompt)
}

// Complete runs one `codex exec` turn for the system+user prompt and returns
// the parsed final agent message. The system prompt is folded into the single
// argv prompt (codex exec has no separate system channel); maxTokens has no
// codex-exec equivalent and is ignored (the prompts already constrain output
// length, and these are tiny completions).
func (g *codexGen) Complete(ctx context.Context, system, user string, _ int) (string, error) {
	prompt := strings.TrimSpace(user)
	if s := strings.TrimSpace(system); s != "" {
		prompt = s + "\n\n" + prompt
	}
	if prompt == "" {
		return "", fmt.Errorf("codexGen: empty prompt")
	}
	argv := codexGenArgv(g.binary, g.model, prompt)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("codexGen: stdout pipe: %w", err)
	}
	var stderrBuf bytes.Buffer
	cmd.Stderr = &limitWriter{w: &stderrBuf, limit: 4096}
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("codexGen: start: %w", err)
	}
	// Collect the LAST agent_message the run emits — the final assistant
	// turn is the answer (earlier ones, if any, are intermediate).
	var last string
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		evs, _, ok := parseCodexStreamLine(sc.Bytes())
		if !ok {
			continue
		}
		for _, e := range evs {
			if e.Role == "assistant" && strings.TrimSpace(e.Text) != "" {
				last = e.Text
			}
		}
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return "", fmt.Errorf("codexGen: timeout: %w", ctx.Err())
	}
	if strings.TrimSpace(last) == "" {
		if waitErr != nil {
			snip := firstMeaningfulLine(stderrBuf.String())
			return "", fmt.Errorf("codexGen: %v (%s)", waitErr, snip)
		}
		return "", fmt.Errorf("codexGen: no agent message in output")
	}
	return last, nil
}

// smallestCodexModel picks the cheapest model id from the discovered codex
// catalog to run the throwaway niceties: it prefers a "-mini" suffix, then
// the entry advertising the fewest reasoning efforts (a proxy for the
// smallest tier), and finally any model. Returns "" when no codex catalog is
// available — codexGen then omits --model and uses codex's own default.
func smallestCodexModel(catalog map[string][]ModelInfo) string {
	models := catalog["codex"]
	if len(models) == 0 {
		return ""
	}
	// Prefer an explicit "-mini" model.
	for _, m := range models {
		if strings.HasSuffix(strings.ToLower(m.ID), "-mini") {
			return m.ID
		}
	}
	// Else the model with the fewest advertised efforts (smallest tier).
	best := ""
	bestEfforts := -1
	for _, m := range models {
		if m.ID == "" {
			continue
		}
		n := len(m.Efforts)
		if bestEfforts < 0 || n < bestEfforts {
			best, bestEfforts = m.ID, n
		}
	}
	return best
}
