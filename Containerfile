# syntax=docker/dockerfile:1.9
#
# claudex: a non-root development container carrying Claude Code and Codex.
#
# Three targets are built from this file:
#   base    all tooling, no agent. The image derived images should build FROM.
#   claude  base + @anthropic-ai/claude-code, CMD claudex-claude
#   codex   base + @openai/codex,             CMD claudex-codex
#
# Design notes that are easy to get wrong later:
#   * There is no sudo. Derived images switch to USER root, install, and switch
#     back to USER dev. See README.md "Building on top of claudex".
#   * The agents live in /opt/npm-global, NOT under $HOME, so that a mounted
#     HOME (devcontainer volume, Kubernetes PVC) cannot hide them. Claude Code's
#     native installer has no install-dir override and follows $HOME, which is
#     why the npm distribution is used instead.
#   * Do NOT add DISABLE_TELEMETRY, DO_NOT_TRACK, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC,
#     DISABLE_GROWTHBOOK, or a custom ANTHROPIC_BASE_URL here. Each one silently
#     disables Claude Code Remote Control, which is this image's primary purpose.
#     https://code.claude.com/docs/en/remote-control#requirements

# Pinned by digest for a reproducible foundation. Tag at time of pinning:
# debian:trixie-slim. Renovate keeps this current.
ARG DEBIAN_DIGEST=sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

# Tooling versions are pinned; agent versions float by design so that a build
# picks up the newest release and a running container can upgrade itself.
# The `# renovate:` comments drive automated version bumps; see renovate.json.

# renovate: datasource=node-version depName=node
ARG NODE_VERSION=22.23.2
# renovate: datasource=github-releases depName=astral-sh/uv
ARG UV_VERSION=0.12.11
# renovate: datasource=github-releases depName=jdx/mise extractVersion=^v(?<version>.*)$
ARG MISE_VERSION=2026.9.3
# renovate: datasource=npm depName=playwright
ARG PLAYWRIGHT_VERSION=1.63.0
# gh comes from upstream releases rather than apt: Debian trixie ships 2.46.0
# (January 2025), which is far behind for a tool used this heavily.
# renovate: datasource=github-releases depName=cli/cli extractVersion=^v(?<version>.*)$
ARG GH_VERSION=2.100.0

# Deliberately unpinned. Override for a reproducible build:
#   --build-arg CLAUDE_CODE_VERSION=2.1.266 --build-arg CODEX_VERSION=0.153.4
#
# These stay build-only and are never promoted to ENV. A running container that
# wants a different agent uses CLAUDEX_CLAUDE_VERSION / CLAUDEX_CODEX_VERSION
# with claudex-upgrade; baking the build pin into the environment would make
# that command a no-op on exactly the images that pinned. What shipped is
# recorded at /opt/npm-global/.claudex-agent-version.
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest


# ---------------------------------------------------------------------------
# fetcher: download and verify the tarball-distributed tools.
# Nothing from this stage's filesystem reaches the final image except /out.
# ---------------------------------------------------------------------------
FROM debian@${DEBIAN_DIGEST} AS fetcher

ARG NODE_VERSION
ARG UV_VERSION
ARG MISE_VERSION
ARG GH_VERSION
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils

# Each tarball is verified against the checksum file published alongside it.
# This catches truncated and tampered downloads; it is not a substitute for
# upstream release signing, which these projects do not uniformly provide.
#
# The three upstreams do not agree on a format: Node and mise publish one
# SHASUMS256.txt covering every asset while uv publishes a per-asset .sha256,
# and mise prefixes its filenames with "./" where Node does not. Hence the
# grep that accepts either a space or a slash before the filename.
WORKDIR /tmp/dl

RUN set -euo pipefail; \
    case "${TARGETARCH}" in \
      amd64) node_arch=x64;   uv_arch=x86_64-unknown-linux-gnu;  mise_arch=linux-x64 ;; \
      arm64) node_arch=arm64; uv_arch=aarch64-unknown-linux-gnu; mise_arch=linux-arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out/opt/node /out/opt/uv/bin /out/opt/mise/bin /out/opt/gh/bin; \
    \
    node_tar="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${node_tar}"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
      | grep " ${node_tar}\$" | sha256sum -c -; \
    tar -xJf "${node_tar}" -C /out/opt/node --strip-components=1; \
    \
    uv_tar="uv-${uv_arch}.tar.gz"; \
    curl -fsSLO "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_tar}"; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_tar}.sha256" \
      | sha256sum -c -; \
    tar -xzf "${uv_tar}" --strip-components=1 -C /out/opt/uv/bin; \
    \
    mise_tar="mise-v${MISE_VERSION}-${mise_arch}.tar.gz"; \
    curl -fsSLO "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${mise_tar}"; \
    curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/SHASUMS256.txt" \
      | grep -E "( |/)${mise_tar}\$" | sha256sum -c -; \
    tar -xzf "${mise_tar}" -C /tmp/dl; \
    install -m 0755 "$(find /tmp/dl/mise -type f -name mise -perm -u+x | head -n1)" /out/opt/mise/bin/mise; \
    \
    gh_tar="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_tar}"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
      | grep -E "( |/)${gh_tar}\$" | sha256sum -c -; \
    tar -xzf "${gh_tar}" -C /tmp/dl; \
    install -m 0755 "/tmp/dl/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /out/opt/gh/bin/gh; \
    \
    /out/opt/node/bin/node --version; \
    /out/opt/uv/bin/uv --version; \
    /out/opt/mise/bin/mise --version; \
    /out/opt/gh/bin/gh --version


# ---------------------------------------------------------------------------
# base: every tool, no agent. Published as claudex-base.
# ---------------------------------------------------------------------------
FROM debian@${DEBIAN_DIGEST} AS base

ARG PLAYWRIGHT_VERSION
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# C.UTF-8 is built into glibc, so a UTF-8 locale costs nothing rather than the
# ~17 MB the `locales` package would add.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NODE_PATH=/opt/npm-global/lib/node_modules \
    NPM_CONFIG_PREFIX=/opt/npm-global \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers \
    CLAUDEX_HOME=/home/dev \
    HOME=/home/dev \
    CLAUDE_CONFIG_DIR=/home/dev/.claude \
    CODEX_HOME=/home/dev/.codex \
    CLAUDEX_WORKDIR=/workspace \
    PATH=/opt/npm-global/bin:/opt/node/bin:/opt/uv/bin:/opt/mise/bin:/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# apt versions deliberately float within the pinned base digest: Debian removes
# superseded versions from the mirror, so exact `=version` pins would break the
# build within weeks for no reproducibility gain the digest does not already give.
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bash-completion \
      build-essential \
      ca-certificates \
      curl \
      fd-find \
      git \
      git-delta \
      gnupg \
      htop \
      jq \
      less \
      libssl-dev \
      nano \
      openssh-client \
      pkg-config \
      procps \
      python3 \
      python3-dev \
      python3-venv \
      ripgrep \
      tini \
      tmux \
      tree \
      unzip \
      vim \
      xz-utils \
 && ln -sf "$(command -v fdfind)" /usr/local/bin/fd

COPY --from=fetcher /out/opt/node /opt/node
COPY --from=fetcher /out/opt/uv /opt/uv
COPY --from=fetcher /out/opt/mise /opt/mise
# Only the binary: the release tarball's man pages and licence would add weight
# for something nobody reads inside a container. `gh completion -s bash`
# regenerates shell completion on demand.
COPY --from=fetcher /out/opt/gh/bin/gh /usr/local/bin/gh

# The runtime user. UID/GID 1000 matches the usual Linux host user so bind
# mounts line up. Group 0 ownership plus setgid dirs let the image also run
# under an arbitrary UID (OpenShift-style runAsUser) without losing write access.
#
# Only /etc/passwd is made group-writable, not /etc/group: the entrypoint adds a
# passwd line for an unknown UID, and that line's GID is 0, a group that already
# exists. Nothing in this image writes /etc/group, so it stays read-only to the
# runtime user. claudex-smoke asserts both halves of this.
RUN groupadd --gid 1000 dev \
 && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && mkdir -p /workspace /opt/npm-global /opt/pw-browsers /home/dev/.claude /home/dev/.codex /home/dev/.local/bin \
 && chown -R 1000:0 /workspace /opt/npm-global /opt/pw-browsers /home/dev \
 && chmod -R g=u /workspace /opt/npm-global /opt/pw-browsers /home/dev \
 && chmod g+s /workspace /opt/npm-global /opt/pw-browsers /home/dev \
 && chgrp 0 /etc/passwd \
 && chmod g+w /etc/passwd

# Playwright's system dependencies need root; the browser itself is installed as
# dev into the shared PLAYWRIGHT_BROWSERS_PATH so every user can read it.
# hadolint ignore=DL3016,DL3008
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
 && playwright install-deps chromium \
 && chown -R 1000:0 /opt/npm-global \
 && chmod -R g=u /opt/npm-global

COPY --chmod=0755 scripts/claudex-entrypoint scripts/claudex-claude scripts/claudex-codex \
     scripts/claudex-upgrade scripts/claudex-smoke /usr/local/bin/
COPY --chmod=0644 scripts/claudex-lib.sh /usr/local/lib/claudex-lib.sh
COPY --chmod=0644 scripts/profile.sh /etc/profile.d/claudex.sh

USER 1000:0

RUN --mount=type=cache,target=/home/dev/.npm,uid=1000,gid=0,sharing=locked \
    playwright install chromium \
 && node --version && python3 --version && uv --version && mise --version && git --version

# Set only after the browser is in place: this variable stops a project's own
# `npm install` from re-downloading a browser that is already baked in.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/claudex-entrypoint"]
CMD ["bash"]

LABEL org.opencontainers.image.title="claudex-base" \
      org.opencontainers.image.description="Non-root development base image with Node, Python, Playwright/Chromium and general development tooling" \
      org.opencontainers.image.source="https://github.com/ColossalTuna/claudex" \
      org.opencontainers.image.licenses="Apache-2.0"


# ---------------------------------------------------------------------------
# claude: base + Claude Code.
# ---------------------------------------------------------------------------
FROM base AS claude

ARG CLAUDE_CODE_VERSION

USER 1000:0
# Agent versions float on purpose; the resolved version is recorded below and
# a running container can upgrade itself with `claudex-upgrade`.
# hadolint ignore=DL3016
RUN --mount=type=cache,target=/home/dev/.npm,uid=1000,gid=0,sharing=locked \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && claude --version \
 && claude --version > /opt/npm-global/.claudex-agent-version

ENV CLAUDEX_AGENT=claude
CMD ["claudex-claude"]

LABEL org.opencontainers.image.title="claudex-claude" \
      org.opencontainers.image.description="claudex base plus Claude Code, launched in Remote Control server mode"


# ---------------------------------------------------------------------------
# codex: base + Codex.
# ---------------------------------------------------------------------------
FROM base AS codex

ARG CODEX_VERSION

USER 1000:0
# hadolint ignore=DL3016
RUN --mount=type=cache,target=/home/dev/.npm,uid=1000,gid=0,sharing=locked \
    npm install -g "@openai/codex@${CODEX_VERSION}" \
 && codex --version \
 && codex --version > /opt/npm-global/.claudex-agent-version

ENV CLAUDEX_AGENT=codex
EXPOSE 9742
CMD ["claudex-codex"]

LABEL org.opencontainers.image.title="claudex-codex" \
      org.opencontainers.image.description="claudex base plus Codex, launched as a headless remote-control app-server"
