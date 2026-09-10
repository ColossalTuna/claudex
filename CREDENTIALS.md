# Credentials

Neither agent ships with credentials and neither can obtain them unattended.
This document covers what each one accepts, and how to get a working credential
into a container that has no browser.

Nothing here is automated by the image. The entrypoint only copies a credential
you supply from a read-only mount into a writable directory; it never reads
credentials out of a running system, and no credential is ever baked into a
layer.

## What each agent accepts

### Claude Code

| credential | model requests | Remote Control |
| --- | --- | --- |
| claude.ai subscription login (`/login`) | yes | **yes** |
| `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) | yes | no |
| `ANTHROPIC_API_KEY` | yes | no |

From the [authentication docs](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token),
on the long-lived token: *"It can only make model requests, so it can't
establish Remote Control sessions or fetch claude.ai connectors."*

So:

- For **headless** use (`claude -p '...'` in a Job or CI), `CLAUDE_CODE_OAUTH_TOKEN`
  is the right answer. Set it as an environment variable from a Secret. It lasts
  a year.
- For **Remote Control**, you need the credential that `/login` writes, and
  there is no device-code flow to produce one without a browser.

Remote Control additionally requires a Pro, Max, Team, or Enterprise plan, an
unset `ANTHROPIC_BASE_URL`, and none of `DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, or `DISABLE_GROWTHBOOK` set. On Team
and Enterprise an owner must enable the Remote Control toggle first.

### Codex

Codex is easier: it has a device-code flow, so a container can log itself in.

```bash
codex login --device-auth      # print a code, approve it in any browser
codex login --with-api-key     # reads the key on stdin
codex login --with-access-token
```

Credentials land in `$CODEX_HOME/auth.json` (`/home/dev/.codex/auth.json` here).

## Getting a credential into a container

### Local and devcontainer: log in once into a persistent home

The agents are installed in `/opt/npm-global`, not in `$HOME`, so a volume
mounted over `/home/dev` hides nothing and persists the login.

```bash
docker run --rm -it \
  -v claudex-home:/home/dev \
  -v /path/to/repo:/workspace \
  ghcr.io/colossaltuna/claudex-claude:latest bash

# inside:
claude          # complete /login; if the browser cannot reach the container's
                # callback, press `c` for the URL and paste the code back
```

Every later container that mounts `claudex-home` starts already logged in.

### Kubernetes: harvest, then seed

A pod has no browser, so the credential is created on a workstation and carried
in as a Secret.

**1. Produce the credential on a machine with a browser.**

```bash
claude                    # complete /login
codex login               # or: codex login --device-auth
```

**2. Harvest the files.**

```bash
# Linux: the credential is a plain file
cp ~/.claude/.credentials.json ./claude-credentials.json

# macOS: it lives in the Keychain unless the Keychain was unwritable. Run
# Claude Code once over SSH, or export the entry from Keychain Access, so that
# you have the same JSON on disk.

cp ~/.codex/auth.json ./codex-auth.json
```

**3. Create the Secret.**

```bash
kubectl create secret generic claudex-credentials \
  --from-file=claude-credentials.json \
  --from-file=codex-auth.json
```

**4. Point the chart at it.**

```bash
helm install claudex deploy/helm/claudex \
  --set credentials.secretName=claudex-credentials \
  --set home.persist=true
```

**5. Delete the local copies.**

```bash
shred -u claude-credentials.json codex-auth.json 2>/dev/null || rm -f claude-credentials.json codex-auth.json
```

## Why the seeding works the way it does

A Kubernetes Secret mounts **read-only**, and both agents refresh their tokens
by writing the credential file back. Pointing `CLAUDE_CONFIG_DIR` straight at
the Secret mount produces a pod that works until the token expires and then
cannot renew itself.

So the entrypoint copies from `/run/secrets/claudex` into the writable
`CLAUDE_CONFIG_DIR` and `CODEX_HOME`, and it **never overwrites an existing
file**. With `home.persist=true` the refreshed credential lives on a PVC and
always wins over the original seed; the Secret is only ever a first-boot value.

Consequences worth planning for:

- With `home.persist=false`, every restart falls back to the Secret's original
  credential. Once that expires the pod stops working until you rotate it.
- A Remote Control session whose login expires stops making progress and cannot
  recover on its own. Claude Code warns three days ahead in an interactive
  session; a server-mode pod has nobody to warn.

## Rotation

1. Run `/login` again on your workstation.
2. Re-harvest and update the Secret:
   `kubectl create secret generic claudex-credentials --from-file=... --dry-run=client -o yaml | kubectl apply -f -`
3. Delete the credential from the PVC so the new seed is used, then restart:
   `kubectl exec deploy/claudex -c claude -- rm -f /home/dev/.claude/.credentials.json`
   `kubectl rollout restart deploy/claudex`

## Handling

- `.credentials.json` and `auth.json` are bearer credentials for your account.
  Treat them like passwords.
- The copy the entrypoint writes is always mode `0600`. The *source* mount's
  mode depends on the deployment: the Helm chart sets `defaultMode: 0400` on the
  Secret volume, but a Compose bind mount just exposes the host file's own
  permissions — `:ro` stops the container writing it, it does not restrict who
  can read it. Set the host file to `0600` yourself before mounting it.
- Nothing in this repository writes a credential into an image layer, a log, or
  a build argument. Keep it that way: build arguments are visible in image
  history.
