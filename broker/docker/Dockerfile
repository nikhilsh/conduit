# swe-kitty single-container broker image.
#
# Distribution model — one container per `docker compose up`, all agents
# pre-installed inside, `swe-kitty-broker` runs as user `app` (uid 1000).
# Per-session isolation is per-process + per-worktree, not per-container.
# This is the swe-swe-shaped pattern (see docs/AGENT-ADAPTERS.md §2):
# claude won't refuse `--dangerously-skip-permissions` because the harness
# itself is not root, and we don't pay the per-session docker-run overhead.
#
# Build from the repo root so the Go module + agent TOMLs are in context:
#   docker build -f broker/docker/Dockerfile -t swekitty/broker:latest .
# Or via docker compose:
#   cd broker/docker && docker compose up -d --build

# Stage 1: cross-compile the harness binary against the linux target the
# runtime image uses. Pin Go to 1.22 to match CI. `--platform=$BUILDPLATFORM`
# keeps the builder running on the runner's native arch (no qemu overhead),
# while honouring $TARGETOS/$TARGETARCH for the output binary — this is the
# canonical buildx pattern for cross-compiled Go images.
FROM --platform=$BUILDPLATFORM golang:1.22-bookworm AS builder

ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY broker/go.mod broker/go.sum ./broker/
RUN cd broker && go mod download

COPY broker ./broker/
ARG RELEASE_TAG=docker-dev
RUN cd broker \
    && CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} go build \
         -trimpath \
         -ldflags "-s -w -X main.version=${RELEASE_TAG}" \
         -o /out/swe-kitty-broker \
         ./cmd/swe-kitty-broker


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

# Claude Code: install via Anthropic's signed apt repo (the docs at
# https://code.claude.com/docs/en/setup recommend the native installer
# OR apt — we use apt inside the image so we don't depend on a network
# bootstrap at first run). The npm path produced a corrupt-on-rerun
# install three separate times on the host today, so it's avoided.
# Repo signing key fingerprint (must match): 31DD DE24 DDFA B679 F42D
# 7BD2 BAA9 29FF 1A7E CACE.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends claude-code \
    && rm -rf /var/lib/apt/lists/*

# Codex: still on npm because OpenAI doesn't publish an apt repo. The
# codex npm package has been stable for us; revisit if it joins the
# claude pattern of failures. Direct-binary install is a future cleanup
# (codex publishes platform binaries on GitHub Releases).
RUN npm install -g @openai/codex \
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

COPY --from=builder /out/swe-kitty-broker /usr/local/bin/swe-kitty-broker

# Agent adapter TOMLs are read by the harness on startup. Ship the
# production set from repo-root `agents/`, not the dev `.swe-kitty/agents/`.
COPY --chown=app:app agents /etc/swe-kitty/agents

USER app
WORKDIR /workspace

ENV HOME=/home/app \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    SWE_KITTY_AGENTS_DIR=/etc/swe-kitty/agents

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/swe-kitty-broker"]
CMD ["up", "--addr", ":1977", "--agents-dir", "/etc/swe-kitty/agents"]
