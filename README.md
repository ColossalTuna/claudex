# claudex

A non-root development container image carrying the latest Claude Code and
Codex, plus the tooling a normal development session needs, built for three
places at once: a devcontainer, a plain `podman run` / `docker run`, and a
Kubernetes pod driven through each agent's remote-control mode.

## Images

Three images are published from one `Containerfile`, on a `v*` git tag only.

| image | contents | use |
| --- | --- | --- |
| `ghcr.io/colossaltuna/claudex-base` | all tooling, no agent | the image to build your own on top of |
| `ghcr.io/colossaltuna/claudex-claude` | base + Claude Code | `claude remote-control` |
| `ghcr.io/colossaltuna/claudex-codex` | base + Codex | `codex remote-control` app-server |

The agent images are the base image plus one layer, so pulling both downloads
the shared base exactly once.

## What is inside

- **Base**: `debian:trixie-slim`, pinned by digest.
- **Runtimes**: Node.js 22 LTS, Python 3 with `uv`, and `mise` for anything else.
- **Browser**: Playwright with Chromium preinstalled to `/opt/pw-browsers`, shared and read-only to every user, with `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` so a project's own `npm install` will not fetch a second copy.
- **Development tools**: git, gh, ripgrep, fd, jq, delta, tmux, vim, nano, htop, tree, less, openssh-client, and a C/C++ build toolchain for native modules and wheels.
- **User**: `dev`, UID/GID 1000, no sudo.

## Quick start

```bash
# Interactive shell with this repo mounted
make build-base
make shell

# Claude Code, Remote Control server mode, against a checkout
docker run --rm -it \
  -v /path/to/repo:/workspace \
  -v claudex-home:/home/dev \
  ghcr.io/colossaltuna/claudex-claude:latest
```

`-it` is not optional for Claude Code: see [TTY](#tty) below.

Both agents need credentials before they can do anything. See
[CREDENTIALS.md](CREDENTIALS.md).

## Configuration

Every knob is an environment variable, so the same image works unchanged in a
devcontainer, a compose file, and a pod spec.

| variable | default | meaning |
| --- | --- | --- |
| `CLAUDEX_WORKDIR` | `/workspace` | directory the agent runs in |
| `CLAUDEX_WORKTREE` | `0` | `1` gives the agent its own git worktree under `.worktrees/<agent>` |
| `CLAUDEX_WORKTREE_BRANCH` | `agent/<agent>` | branch for that worktree |
| `CLAUDEX_PTY` | `0` | `1` synthesizes a PTY with `script(1)` instead of requiring one |
| `CLAUDEX_SKIP_PERMISSIONS` | `0` | `1` passes `--dangerously-skip-permissions` to Claude Code |
| `CLAUDEX_SEED_TRUST` | `1` | pre-accept Claude Code's workspace trust dialog for `CLAUDEX_WORKDIR` |
| `CLAUDEX_SECRETS_DIR` | `/run/secrets/claudex` | read-only credential mount to seed from |
| `CLAUDEX_CODEX_LISTEN` | unset | Codex app-server listen address; unset means loopback only |
| `CLAUDEX_CODEX_TOKEN_FILE` | unset | token file for Codex WebSocket authentication |
| `CLAUDEX_MISE_ACTIVATE` | unset | activate `mise` in interactive login shells |
| `CLAUDE_CONFIG_DIR` | `/home/dev/.claude` | Claude Code config and credentials |
| `CODEX_HOME` | `/home/dev/.codex` | Codex config and credentials |

Commands on `PATH`: `claudex-claude`, `claudex-codex`, `claudex-upgrade`,
`claudex-smoke`.

## Two agents, one workspace

The agents are meant to review each other's work without pushing anywhere. That
needs a shared filesystem, which both supported topologies provide:

- **Kubernetes**: one pod, two containers, one shared workspace volume. Pod
  containers also share a network namespace, so Claude Code can reach Codex's
  app-server on `127.0.0.1:9742`. This is what the Helm chart deploys.
- **Local**: `deploy/compose.yaml`, two services on one shared volume. Here the
  agents reach each other by service name rather than loopback.

Set `CLAUDEX_WORKTREE=1` on both so each works in its own git worktree. They
share one object store, so `git diff agent/claude agent/codex` works with no
remote involved, and neither can overwrite the other's files.

```bash
helm install claudex deploy/helm/claudex \
  --set credentials.secretName=claudex-credentials \
  --set workspace.type=pvc
```

## Building on top of claudex

There is no sudo, on purpose: the way to add tooling is a derived image, so what
you run is what you built. Switch users around the install:

```dockerfile
FROM ghcr.io/colossaltuna/claudex-base:latest

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*

USER 1000:0
RUN npm install -g some-tool
```

Node packages installed as `dev` land in `/opt/npm-global`, which is outside
`$HOME` and therefore survives a mounted home volume.

## Upgrading the agents in a running container

The agents live in `/opt/npm-global`, owned by the runtime user, so they upgrade
without root and without a rebuild:

```bash
claudex-upgrade          # whichever agent is installed
claudex-upgrade all
```

The upgrade lives in the container's writable layer and is gone after a
restart, which is intended: the image is the source of truth.

## Traps worth knowing

### Do not disable telemetry here

Setting any of `DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, or `DISABLE_GROWTHBOOK`, or pointing
`ANTHROPIC_BASE_URL` at anything other than `api.anthropic.com`, **silently
disables Claude Code Remote Control**, which is the main reason this image
exists. The launchers warn if they see one set. See the
[Remote Control requirements](https://code.claude.com/docs/en/remote-control).

### TTY

`claude remote-control` renders a terminal UI even though the interaction
happens remotely, so it needs a PTY. Provide one:

- `docker run -it` / `podman run -it`
- Kubernetes: `stdin: true` and `tty: true` on the container (the Helm chart
  sets both)
- or set `CLAUDEX_PTY=1` to have the launcher synthesize one with `script(1)`

Without a PTY the launcher exits immediately with instructions rather than
hanging. A daemonizable headless mode is
[an open upstream request](https://github.com/anthropics/claude-code/issues/30447).
Codex's `remote-control` is headless already and needs none of this.

### API keys will not get you Remote Control

`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` authenticate model requests
but cannot establish a Remote Control session; that needs a claude.ai
subscription login. [CREDENTIALS.md](CREDENTIALS.md) covers how to get one into
a container that has no browser.

### Arbitrary UIDs

The image runs as UID 1000 by default but tolerates any UID, provided the
supplementary group is 0. Writable paths are group-0 owned and setgid, and the
entrypoint adds a `/etc/passwd` entry for an unknown UID so `whoami`, `git`, and
`~` behave. `make test-arbitrary-uid` and CI both verify this.

Making that work requires `/etc/passwd` to be group-0 writable, which is the
standard OpenShift-compatible pattern. It lets a process in the container add a
name-to-UID mapping. It does not grant privilege: `/etc/shadow` is untouched,
there is no setuid binary to abuse, and no sudo. If your threat model rules it
out anyway, drop the `chgrp 0 /etc/passwd` line from the Containerfile and pin
`runAsUser: 1000`.

## Development

```bash
make help              # every target
make build             # all three images, host architecture
make test              # smoke test all three, plus the arbitrary-UID case
make lint              # hadolint, shellcheck, helm lint
make versions          # what actually got baked in
```

CI builds all three images for amd64, smoke tests them, and builds arm64 to
prove it compiles, on every push. Nothing is published until a `v*` tag, which
triggers a multi-architecture build, push to GHCR, SBOM, and a keyless cosign
signature.

## License

Apache-2.0. See [LICENSE](LICENSE).
