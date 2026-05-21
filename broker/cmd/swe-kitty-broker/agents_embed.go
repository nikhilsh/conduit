package main

import "embed"

// Default agent adapter TOMLs shipped inside the harness binary so a
// freshly-installed `swe-kitty-broker up` works zero-config. Override
// by passing `--agents-dir <path>` or placing TOMLs in
// `~/.swe-kitty/agents/`.
//
//go:embed embedded-agents/*.toml
var embeddedAgents embed.FS
