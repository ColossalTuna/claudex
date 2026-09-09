# shellcheck shell=bash
#
# Shared helpers for the claudex launchers. Sourced, never executed.

claudex_log() { printf 'claudex: %s\n' "$*" >&2; }
claudex_die() { claudex_log "$*"; exit 1; }

# Resolve the directory the agent runs in. CLAUDEX_WORKDIR is the contract;
# /workspace is the default and the image's WORKDIR.
claudex_resolve_workdir() {
  local dir="${CLAUDEX_WORKDIR:-/workspace}"
  [[ -d "$dir" ]] || claudex_die "CLAUDEX_WORKDIR=$dir does not exist. Mount a directory there."
  [[ -w "$dir" ]] || claudex_log "warning: $dir is not writable by uid $(id -u); the agent will not be able to edit files"
  printf '%s' "$dir"
}

# Optional per-agent git worktree so two agents can work in one repository
# without touching each other's files, while still sharing one object store.
# Off by default. Set CLAUDEX_WORKTREE=1 to enable.
#
# Prints the directory the agent should run in.
claudex_prepare_worktree() {
  local repo="$1" agent="${2:-agent}"

  case "${CLAUDEX_WORKTREE:-0}" in
    1|true|yes|on) ;;
    *) printf '%s' "$repo"; return 0 ;;
  esac

  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    claudex_log "warning: CLAUDEX_WORKTREE is set but $repo is not a git repository; running in $repo"
    printf '%s' "$repo"
    return 0
  fi

  local worktree="${CLAUDEX_WORKTREE_ROOT:-$repo/.worktrees}/$agent"
  local branch="${CLAUDEX_WORKTREE_BRANCH:-agent/$agent}"

  # Keep the worktree root out of `git status` without editing a tracked
  # .gitignore that belongs to the user's repository.
  local exclude
  exclude="$(git -C "$repo" rev-parse --git-common-dir)/info/exclude"
  if [[ -f "$exclude" ]] && ! grep -qxF '/.worktrees/' "$exclude" 2>/dev/null; then
    printf '/.worktrees/\n' >> "$exclude" 2>/dev/null \
      || claudex_log "warning: could not append to $exclude"
  fi

  if git -C "$repo" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $worktree"; then
    claudex_log "reusing existing worktree $worktree"
  elif [[ -e "$worktree" ]]; then
    claudex_log "warning: $worktree exists but is not a registered worktree; running in $repo"
    printf '%s' "$repo"
    return 0
  elif git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add "$worktree" "$branch" >&2 \
      || { claudex_log "warning: could not add worktree; running in $repo"; printf '%s' "$repo"; return 0; }
  else
    git -C "$repo" worktree add -b "$branch" "$worktree" >&2 \
      || { claudex_log "warning: could not add worktree; running in $repo"; printf '%s' "$repo"; return 0; }
  fi

  printf '%s' "$worktree"
}

# Claude Code's `remote-control` server renders a terminal UI even though all
# interaction happens remotely, so it needs a PTY. The documented contract is
# that the caller provides one (`docker run -it`, or `tty: true` plus
# `stdin: true` in a pod spec). CLAUDEX_PTY=1 opts into synthesizing one with
# script(1) for callers that cannot.
#
# Upstream feature request for a real headless mode:
# https://github.com/anthropics/claude-code/issues/30447
claudex_exec_agent() {
  local pty="${CLAUDEX_PTY:-0}"

  case "$pty" in
    1|true|yes|on)
      local quoted
      quoted="$(printf '%q ' "$@")"
      claudex_log "CLAUDEX_PTY is set; wrapping in script(1) to synthesize a PTY"
      exec script -qec "$quoted" /dev/null
      ;;
    *)
      if [[ ! -t 0 || ! -t 1 ]]; then
        claudex_log "no TTY attached."
        claudex_log "  docker/podman: add -it"
        claudex_log "  kubernetes:    set stdin: true and tty: true on the container"
        claudex_log "  or set CLAUDEX_PTY=1 to synthesize a PTY with script(1)"
        exit 64
      fi
      exec "$@"
      ;;
  esac
}
