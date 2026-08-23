# syntax=docker/dockerfile:1

# ── builder ─────────────────────────────────────────────────────────────────
# Full workspace install + complete build (lib bundles + web frontend dist).
# The client build embeds a git commit hash; pass DSH_CLIENT_COMMIT_HASH so
# the build works without the .git directory (default 0000000 passes the gate).
FROM node:22-bookworm-slim AS builder

ARG DSH_CLIENT_COMMIT_HASH=0000000

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    DSH_CLIENT_COMMIT_HASH=$DSH_CLIENT_COMMIT_HASH \
    CI=true \
    PNPM_CONFIG_FETCH_TIMEOUT=600000 \
    PNPM_CONFIG_FETCH_RETRIES=5 \
    PNPM_CONFIG_NETWORK_CONCURRENCY=8

RUN corepack enable

# Minimal toolchain: some transitive deps run node-gyp at install time.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Manifests and shared config first for layer caching.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY tsconfig.base.json tsconfig.base.client.json tsconfig.client.json tsconfig.host.json tsconfig.json tsdown.config.ts ./
COPY .gitattributes .gitignore .editorconfig ./
COPY patches ./patches
COPY vendor ./vendor
COPY packages ./packages
COPY apps ./apps
COPY native ./native
COPY examples ./examples
COPY python ./python
COPY scripts ./scripts
COPY website ./website

RUN pnpm install --frozen-lockfile
RUN pnpm run build

# ── runtime ─────────────────────────────────────────────────────────────────
# Ships the full workspace incl. node_modules: the web profile resolves every
# plugin through workspace links, and apps/cli's web bundle keeps some of its
# plugin packages in devDependencies, so pruning dev deps would break boot.
FROM node:22-bookworm-slim AS runtime

ENV NODE_ENV=production \
    DSH_HOME=/root/.dsh

WORKDIR /app

COPY --from=builder /app ./

EXPOSE 3080
VOLUME ["/root/.dsh"]

# The web profile intentionally rejects --host 0.0.0.0 (remote code execution
# guard). Serve on loopback and expose via SSH port forwarding or a reverse
# proxy; a proxy or public hostname needs the /api browser-trust fence to
# accept it: add `--trusted-host <hostname>[:port]` to CMD.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3080/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["node", "apps/cli/lib/bin.js"]
CMD ["web", "--no-open"]