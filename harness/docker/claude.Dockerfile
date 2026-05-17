FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Assumption: Claude Code ships on npm as @anthropic-ai/claude-code.
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /workspace

COPY harness/docker/entrypoint-template.sh /swekitty/entrypoint-template.sh
COPY harness/docker/claude-entrypoint.sh /swekitty/entrypoint.sh
RUN chmod +x /swekitty/entrypoint-template.sh /swekitty/entrypoint.sh

ENTRYPOINT ["/swekitty/entrypoint.sh"]
