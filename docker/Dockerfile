# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim AS build

WORKDIR /build

# The rc.8 client build embeds this value; Dockerfile.dockerignore excludes
# .git, so callers must provide the exact source revision explicitly.
ARG DSH_CLIENT_COMMIT_HASH
ARG DSH_CLIENT_REMOTE_SETTINGS=1
ENV DSH_CLIENT_COMMIT_HASH=${DSH_CLIENT_COMMIT_HASH} \
    DSH_CLIENT_REMOTE_SETTINGS=${DSH_CLIENT_REMOTE_SETTINGS}

RUN case "$DSH_CLIENT_REMOTE_SETTINGS" in 0|1) ;; *) echo 'DSH_CLIENT_REMOTE_SETTINGS must be 0 or 1' >&2; exit 1 ;; esac

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        build-essential \
        ca-certificates \
        git \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable \
    && corepack prepare pnpm@11.7.0 --activate \
    && test "$(pnpm --version)" = "11.7.0"

COPY . .

RUN git apply --check docker/patches/insecure-origin-rpc.patch \
    && git apply docker/patches/insecure-origin-rpc.patch \
    && rm docker/patches/insecure-origin-rpc.patch

RUN pnpm install --frozen-lockfile
RUN pnpm run build

FROM node:22-bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        apache2-utils \
        bash \
        build-essential \
        ca-certificates \
        curl \
        git \
        nginx \
        openssh-client \
        procps \
        python3 \
        ripgrep \
        tini \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 dsh \
    && useradd --system --uid 10001 --gid dsh --create-home --home-dir /home/dsh --shell /usr/sbin/nologin dsh

# Keep the official Linux CLI and plugin-management toolchain available in the
# final image, not only in the build stage. `dsh plugin` forwards to pnpm.
ENV COREPACK_HOME=/opt/corepack
RUN corepack enable \
    && install -d -o dsh -g dsh -m 0755 "$COREPACK_HOME" \
    && corepack prepare pnpm@11.7.0 --activate \
    && test "$(pnpm --version)" = "11.7.0"

COPY --chown=dsh:dsh --from=build /build /opt/dsh
COPY docker/entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY docker/nginx.conf /etc/nginx/nginx.conf

RUN rm -f /usr/local/bin/pnpm /usr/local/bin/pnpx \
    && printf '%s\n' \
        '#!/usr/bin/env bash' \
        'exec env "CI=${CI:-true}" /usr/local/bin/corepack pnpm "$@"' \
        > /usr/local/bin/pnpm \
    && printf '%s\n' \
        '#!/usr/bin/env bash' \
        'exec env "CI=${CI:-true}" /usr/local/bin/corepack pnpx "$@"' \
        > /usr/local/bin/pnpx \
    && chmod 0555 /usr/local/bin/pnpm /usr/local/bin/pnpx

RUN printf '%s\n' \
        '#!/usr/bin/env bash' \
        'exec node /opt/dsh/apps/cli/lib/bin.js "$@"' \
        > /usr/local/bin/dsh \
    && chmod 0555 /usr/local/bin/dsh

RUN install -d -o dsh -g dsh -m 0700 \
        /home/dsh \
        /run/dsh-auth \
        /workspace \
        /tmp/dsh-nginx-client-body \
        /tmp/dsh-nginx-proxy \
        /tmp/dsh-nginx-fastcgi \
        /tmp/dsh-nginx-uwsgi \
        /tmp/dsh-nginx-scgi \
    && chmod 0555 /usr/local/bin/dsh-entrypoint

ENV HOME=/home/dsh \
    DSH_HOME=/home/dsh \
    PATH=/opt/dsh/node_modules/.bin:/opt/dsh/apps/cli/node_modules/.bin:${PATH}

WORKDIR /workspace
VOLUME ["/home/dsh", "/workspace"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["curl", "--fail", "--silent", "--show-error", "--max-time", "5", "http://127.0.0.1:8080/healthz"]

USER dsh
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint"]
