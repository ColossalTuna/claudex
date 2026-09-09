# shellcheck shell=sh
# claudex PATH wiring for login shells.
#
# The image sets ENV PATH, which covers `docker exec`, pod commands, and
# non-login shells. A login shell (`bash -l`, `su - dev`, some terminal
# emulators) resets PATH from /etc/profile, so it is repeated here.
case ":${PATH}:" in
  *":/opt/npm-global/bin:"*) ;;
  *) PATH="/opt/npm-global/bin:/opt/node/bin:/opt/uv/bin:/opt/mise/bin:${HOME:-/home/dev}/.local/bin:${PATH}" ;;
esac
export PATH

# mise activation is opt-in: it rewrites PATH on every prompt, which is useful
# for a human shell and unhelpful inside a one-shot agent process.
if [ -n "${CLAUDEX_MISE_ACTIVATE:-}" ] && command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
