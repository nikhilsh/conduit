# swe-kitty single-container harness image.
#
# Distribution model — one container per `docker compose up`, all agents
# pre-installed inside, `swe-kitty-harness` runs as user `app` (uid 1000).
# Per-session isolation is per-process + per-worktree, not per-container.
# This is the swe-swe-shaped pattern (see docs/AGENT-ADAPTERS.md §2):
# claude won't refuse `--dangerously-skip-permissions` because the harness
# itself is not root, and we don't pay the per-session docker-run overhead.
#
# Build from the repo root so the Go module + agent TOMLs are in context:
#   docker build -f harness/docker/Dockerfile -t swekitty/harness:latest .
# Or via docker compose:
#   cd harness/docker && docker compose up -d --build

# Stage 1: cross-compile the harness binary against the linux target the
# runtime image uses. Pin Go to 1.22 to match CI.
FROM golang:1.22-bookworm AS builder

WORKDIR /src
COPY harness/go.mod harness/go.sum ./harness/
RUN cd harness && go mod download

COPY harness ./harness/
ARG RELEASE_TAG=docker-dev
RUN cd harness \
    && CGO_ENABLED=0 GOOS=linux go build \
         -trimpath \
         -ldflags "-s -w -X main.version=${RELEASE_TAG}" \
         -o /out/swe-kitty-harness \
         ./cmd/swe-kitty-harness


# Stage 2: runtime — node base + all the agent CLIs we ship adapters for.
# node:22 is the lowest-friction base for claude/codex (npm-distributed).
FROM node:22-bookworm-slim AS runtime

# tini reaps zombie processes — important because the harness PTY-spawns
# agents and an agent crash should not leave a defunct on the box.
# procps gives us ps for swe-swe-style sanity-check from `docker exec`.
# git is required by every agent's workspace mutation flow.
# jq + curl + openssl are useful from inside agent shells (write code that
# probes URLs, parses JSON, etc.).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssl \
        procps \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Pre-install every agent we ship a TOML adapter for. Adding a new agent =
# one npm install line + one agents/*.toml — no per-agent Dockerfile.
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
    && npm cache clean --force

# Single, swe-swe-shaped non-root user. uid 1000 lines up with how most
# users bind-mount their workspace so file ownership inside the container
# matches the host. node:22-bookworm-slim already has a `node` user at
# uid 1000 — remove it first so the rename to `app` is clean.
RUN userdel --remove node 2>/dev/null || true \
    && groupadd --gid 1000 app \
    && useradd --create-home --shell /bin/bash --uid 1000 --gid 1000 app \
    && mkdir -p /workspace /worktrees /home/app/.swe-kitty \
    && chown -R app:app /workspace /worktrees /home/app

COPY --from=builder /out/swe-kitty-harness /usr/local/bin/swe-kitty-harness

# Agent adapter TOMLs are read by the harness on startup. Ship the
# production set from repo-root `agents/`, not the dev `.swe-kitty/agents/`.
COPY --chown=app:app agents /etc/swe-kitty/agents

USER app
WORKDIR /workspace

ENV HOME=/home/app \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    SWE_KITTY_AGENTS_DIR=/etc/swe-kitty/agents

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/swe-kitty-harness"]
CMD ["up", "--addr", ":1977", "--agents-dir", "/etc/swe-kitty/agents"]
