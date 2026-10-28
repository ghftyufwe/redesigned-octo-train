FROM node:22-slim AS builder
WORKDIR /app
ENV NODE_ENV=development
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
ARG SOURCE_REV=railway-security-hardening-20260826-v1
RUN test -n "$SOURCE_REV"

# vite.config.ts inlines the Supabase browser config at build time via
# `define`, reading process.env inside the build. A Dockerfile build only sees
# variables declared as ARG, so these must be declared here or `vite build`
# runs with none of them and ships a bundle whose login screen cannot work
# (observed live with the earlier Firebase config: the app rendered but
# reported "Authentication is disabled"). Railway passes service variables to
# the build as ARGs of the same name.
#
# These are the Supabase *browser* values, not secrets: the project URL and a
# publishable key. They are compiled into client JavaScript and readable by
# anyone who loads the page. Access is controlled by Supabase RLS and by
# server-side token verification in requireAuth, not by hiding these.
# SPR_REQUIRE_SUPABASE_CONFIG makes vite.config.ts fail the build when they are
# missing instead of producing a broken bundle.
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_PUBLISHABLE_KEY
ENV SPR_REQUIRE_SUPABASE_CONFIG=true     VITE_SUPABASE_URL=$VITE_SUPABASE_URL     VITE_SUPABASE_PUBLISHABLE_KEY=$VITE_SUPABASE_PUBLISHABLE_KEY

COPY . ./
# Production builds remain a release gate. GitHub Actions is not currently
# reliable enough to be the sole verifier, so keep the full suite here. Vitest
# itself caps concurrency to avoid PGlite starvation on Railway builders.
RUN npm run typecheck && npm test && npm run build

# The Supabase requirement itself is enforced inside vite.config.ts, which holds
# the actual values; this only confirms the client build produced something to
# serve, so a missing bundle fails the build instead of the healthcheck.
RUN test -f dist/index.html || (echo 'FATAL: vite build produced no dist/index.html' && exit 1)
RUN npm run build:owner-bootstrap
RUN npm prune --omit=dev --no-audit --no-fund

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

# This is the API image. The production worker is built separately from
# Dockerfile.worker. The API image still includes the repository-scan toolchain
# and ClamAV because API-side scan and specialist-delivery paths invoke those
# binaries directly. Keep worker-only assumptions in Dockerfile.worker.
ENV SYFT_PATH=/usr/local/bin/syft
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git unzip tar && rm -rf /var/lib/apt/lists/* \
      && arch="$(dpkg --print-architecture)" \
  && case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac \
  && case "$arch" in \
       amd64) clam_arch=x86_64; clam_sha=d3ee9e401974855a1edc1761b1425417d126de618d5f0c91cd51209f69f6fcc2 ;; \
       arm64) clam_arch=aarch64; clam_sha=a29cc95aeb225f0dc1b99024b49f1cc109502cb17aaf168637d0901aa9674fe8 ;; \
     esac \
  && curl -fsSL --retry 2 --retry-all-errors --connect-timeout 15 --max-time 180 "https://github.com/Cisco-Talos/clamav/releases/download/clamav-1.4.6/clamav-1.4.6.linux.${clam_arch}.deb" -o /tmp/clamav.deb \
  && echo "$clam_sha  /tmp/clamav.deb" | sha256sum -c - \
  && dpkg -i /tmp/clamav.deb \
  && ldconfig \
  && rm -f /tmp/clamav.deb /usr/local/lib/libclamav_rust.a \
  && ln -s /var/lib/clamav /usr/local/share/clamav \
  && clamscan --version | grep -E '^ClamAV 1[.]4[.]6(/|$)' \
  && curl -fsSL "https://github.com/anchore/syft/releases/download/v1.49.0/syft_1.49.0_linux_${arch}.tar.gz" -o /tmp/syft.tar.gz \
  && tar -xzf /tmp/syft.tar.gz -C /usr/local/bin syft \
  && chmod 0755 /usr/local/bin/syft \
  && rm -f /tmp/syft.tar.gz \
  && /usr/local/bin/syft version | grep -F '1.49.0' \
  && groupadd --system --gid 10001 spr && useradd --system --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin spr

# Official 1.4.6 packages are pinned to GitHub release-asset SHA-256 digests.
# The upstream default database path is linked to the fixed freshclam directory.
# Binaries alone do not enable delivery: current signatures and acceptance checks are required.
RUN command -v clamscan >/dev/null && command -v freshclam >/dev/null \
  && install -d -o 10001 -g 10001 -m 0750 /var/lib/clamav
COPY config/specialist-freshclam.conf /app/config/specialist-freshclam.conf
COPY scripts/verify-specialist-scanner.mjs /app/scripts/verify-specialist-scanner.mjs

COPY --from=builder --chown=10001:10001 /app/package.json ./
COPY --from=builder --chown=10001:10001 /app/node_modules ./node_modules
COPY --from=builder --chown=10001:10001 /app/dist ./dist
COPY --from=builder --chown=10001:10001 /app/migrations ./migrations
COPY --from=builder --chown=10001:10001 /app/data ./data
COPY --from=builder --chown=10001:10001 /app/index.html ./index.html

RUN ! find /app -type f \( -name 'firebase-applet-config.json' -o -name '.env' -o -name '*.pem' -o -name '*.key' -o -name 'secret*.json' \) -print -quit | grep -q .

EXPOSE 8080
USER 10001:10001
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl -fsS "http://127.0.0.1:${PORT:-8080}/health" || exit 1
CMD ["sh", "-c", "case \"$PROCESS_ROLE\" in worker) exec node dist/worker.cjs ;; bootstrap) exec node dist/bootstrap-initial-owner.cjs ;; migrate) exec node dist/migrate.cjs ;; *) exec node dist/server.cjs ;; esac"]
