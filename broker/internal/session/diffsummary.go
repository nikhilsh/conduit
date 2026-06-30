package session

import (
	"bytes"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// reDiffSummaryLine matches the final summary line of `git diff --stat` output:
//
//	3 files changed, 47 insertions(+), 12 deletions(-)
//	1 file changed, 5 insertions(+)
//	2 files changed, 0 insertions(+), 8 deletions(-)
var reDiffSummaryLine = regexp.MustCompile(
	`(\d+) files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?`,
)

// DiffSummary runs `git diff --stat <base>...HEAD` in workdir and returns
// parsed counts + the raw stat text. Returns zero values + err on failure.
// base is typically a branch name like "main".
func DiffSummary(workdir, base string) (filesChanged, insertions, deletions int, stat string, err error) {
	if workdir == "" {
		return 0, 0, 0, "", fmt.Errorf("diffsummary: workdir is empty")
	}
	if base == "" {
		return 0, 0, 0, "", fmt.Errorf("diffsummary: base is empty")
	}
	ref := base + "...HEAD"
	cmd := exec.Command("git", "diff", "--stat", ref)
	cmd.Dir = workdir
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return 0, 0, 0, "", fmt.Errorf("diffsummary: git diff --stat %s failed: %s", ref, strings.TrimSpace(errBuf.String()))
	}
	stat = strings.TrimSpace(outBuf.String())
	if stat == "" {
		// No diff — all counts are zero, not an error.
		return 0, 0, 0, "", nil
	}
	m := reDiffSummaryLine.FindStringSubmatch(stat)
	if m == nil {
		return 0, 0, 0, stat, fmt.Errorf("diffsummary: could not parse summary line from: %q", stat)
	}
	filesChanged = mustAtoi(m[1])
	if m[2] != "" {
		insertions = mustAtoi(m[2])
	}
	if m[3] != "" {
		deletions = mustAtoi(m[3])
	}
	return filesChanged, insertions, deletions, stat, nil
}

func mustAtoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}
