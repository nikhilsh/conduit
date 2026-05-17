FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Assumption: the OpenAI Codex CLI ships on npm as @openai/codex.
RUN npm install -g @openai/codex

WORKDIR /workspace

COPY harness/docker/entrypoint-template.sh /swekitty/entrypoint-template.sh
COPY harness/docker/codex-entrypoint.sh /swekitty/entrypoint.sh
RUN chmod +x /swekitty/entrypoint-template.sh /swekitty/entrypoint.sh

ENTRYPOINT ["/swekitty/entrypoint.sh"]
