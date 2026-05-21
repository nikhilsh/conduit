package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/nikhilsh/swe-kitty/broker/internal/memory"
)

var (
	memoryStdout io.Writer = os.Stdout
	memoryStderr io.Writer = os.Stderr
)

func runMemory(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(memoryStderr, "usage: swe-kitty-broker memory <init|render|checkpoint|handoff|promote|show>")
		return 2
	}
	root := "."
	switch args[0] {
	case "init":
		fs := flag.NewFlagSet("init", flag.ExitOnError)
		fs.StringVar(&root, "root", root, "repo root")
		_ = fs.Parse(args[1:])
		if err := memory.Init(root); err != nil {
			fmt.Fprintln(memoryStderr, err)
			return 1
		}
		return 0
	case "render":
		fs := flag.NewFlagSet("render", flag.ExitOnError)
		sessionID := fs.String("session", "", "session uuid")
		fs.StringVar(&root, "root", root, "repo root")
		_ = fs.Parse(args[1:])
		if *sessionID == "" {
			fmt.Fprintln(memoryStderr, "--session is required")
			return 2
		}
		content, err := memory.Render(root, *sessionID)
		if err != nil {
			fmt.Fprintln(memoryStderr, err)
			return 1
		}
		_, _ = io.WriteString(memoryStdout, content)
		return 0
	case "checkpoint":
		fs := flag.NewFlagSet("checkpoint", flag.ExitOnError)
		sessionID := fs.String("session", "", "session uuid")
		reason := fs.String("reason", "manual", "checkpoint reason")
		worktree := fs.String("worktree", "", "worktree path")
		branch := fs.String("branch", "", "branch name")
		task := fs.String("task", "", "task id")
		agent := fs.String("agent", "", "agent name")
		created := fs.String("created", "", "created timestamp")
		at := fs.String("at", "", "checkpoint timestamp")
		taskBrief := fs.String("task-brief", "", "task brief path")
		taskSummary := fs.String("task-summary", "", "task summary")
		tailFile := fs.String("tail-file", "", "file with scrollback tail")
		fs.StringVar(&root, "root", root, "repo root")
		_ = fs.Parse(args[1:])
		if *sessionID == "" {
			fmt.Fprintln(memoryStderr, "--session is required")
			return 2
		}
		var createdAt time.Time
		var checkpointAt time.Time
		var err error
		if *created != "" {
			createdAt, err = time.Parse(time.RFC3339Nano, *created)
			if err != nil {
				fmt.Fprintln(memoryStderr, err)
				return 2
			}
		}
		if *at != "" {
			checkpointAt, err = time.Parse(time.RFC3339Nano, *at)
			if err != nil {
				fmt.Fprintln(memoryStderr, err)
				return 2
			}
		}
		tail := ""
		if *tailFile != "" {
			raw, err := os.ReadFile(*tailFile)
			if err != nil {
				fmt.Fprintln(memoryStderr, err)
				return 1
			}
			tail = string(raw)
		}
		rendered, err := memory.Checkpoint(root, memory.CheckpointOptions{
			SessionData: memory.SessionData{
				SessionID:      *sessionID,
				WorktreePath:   *worktree,
				Branch:         *branch,
				TaskID:         *task,
				CurrentAgent:   *agent,
				CreatedAt:      createdAt,
				CheckpointAt:   checkpointAt,
				TaskBriefPath:  *taskBrief,
				TaskSummary:    *taskSummary,
				ScrollbackTail: tail,
			},
			Reason: *reason,
		})
		if err != nil {
			fmt.Fprintln(memoryStderr, err)
			return 1
		}
		_, _ = io.WriteString(memoryStdout, rendered)
		return 0
	case "handoff":
		fs := flag.NewFlagSet("handoff", flag.ExitOnError)
		sessionID := fs.String("session", "", "session uuid")
		from := fs.String("from", "", "from agent")
		to := fs.String("to", "", "to agent")
		reason := fs.String("reason", "", "handoff reason")
		handoffPath := fs.String("handoff-path", "", "source handoff html")
		fs.StringVar(&root, "root", root, "repo root")
		_ = fs.Parse(args[1:])
		if *sessionID == "" || *from == "" || *to == "" {
			fmt.Fprintln(memoryStderr, "--session, --from, and --to are required")
			return 2
		}
		rendered, err := memory.Handoff(root, memory.HandoffOptions{
			SessionID:   *sessionID,
			From:        *from,
			To:          *to,
			Reason:      *reason,
			HandoffPath: *handoffPath,
		})
		if err != nil {
			fmt.Fprintln(memoryStderr, err)
			return 1
		}
		_, _ = io.WriteString(memoryStdout, rendered)
		return 0
	case "promote":
		fs := flag.NewFlagSet("promote", flag.ExitOnError)
		sessionID := fs.String("session", "", "session uuid")
		decisionID := fs.String("decision", "", "decision id")
		fs.StringVar(&root, "root", root, "repo root")
		_ = fs.Parse(args[1:])
		if *sessionID == "" || *decisionID == "" {
			fmt.Fprintln(memoryStderr, "--session and --decision are required")
			return 2
		}
		result, err := memory.Promote(root, *sessionID, *decisionID, time.Now().UTC())
		if err != nil {
			fmt.Fprintln(memoryStderr, err)
			return 1
		}
		_, _ = fmt.Fprintf(memoryStdout, "promoted %s\n%s\n", result.SourceDecisionID, result.PromotedDecision)
		return 0
	case "show":
		fs := flag.NewFlagSet("show", flag.ExitOnError)
		sessionID := fs.String("session", "", "session uuid")
		fs.StringVar(&root, "root", root, "repo root")
		_ = fs.Parse(args[1:])
		content, err := memory.Show(root, *sessionID)
		if err != nil {
			fmt.Fprintln(memoryStderr, err)
			return 1
		}
		_, _ = io.WriteString(memoryStdout, content)
		return 0
	default:
		fmt.Fprintf(memoryStderr, "unknown memory command: %s\n", args[0])
		return 2
	}
}
