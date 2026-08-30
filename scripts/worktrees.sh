#!/usr/bin/env bash
# Reconcile worktrees and branches against desired state.
#
# Usage: worktrees.sh <workspace-dir> [--apply] [--prune-merged]
#   Default: dry run. --apply executes. --prune-merged adds the delete pass.
#
# One pass, four decisions per branch:
#   merged into origin/main with no upstream (vercel-labs/fx) PR and no
#     uncommitted work  -> delete worktree + branch (--prune-merged)
#   active local branch -> worktree at <workspace>/<branch>; / -> -
#   main / master       -> worktree at <workspace>/main
#   backup/*, refs/backup/* snapshots -> never mounted, prune candidates
#
# Never touched: dirty worktrees, detached checkouts, mismatches (reported
# instead; exit 1). Nothing here stashes, resets, or force-deletes unmerged
# work.
#
# Upstream-refresh policy (formerly .fx/skills/upstream-refresh/SKILL.md):
# run "scripts/upstream_refresh.py prepare", resolve conflicts in the
# session-owned integration worktree only, prefer upstream architecture and
# preserve intentional fork features, then "apply --plan <file>". Never
# blanket checkout --ours/--theirs, reset worktrees, or discard uncommitted
# work. Backup refs land under refs/backup/omifx-upstream-refresh/.
set -euo pipefail

APPLY=0; PRUNE=0; WS=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --prune-merged) PRUNE=1 ;;
    *) WS="$arg" ;;
  esac
done
[[ -n "$WS" ]] || { echo "usage: worktrees.sh <workspace-dir> [--apply] [--prune-merged]"; exit 2; }
mkdir -p "$WS"

MAIN="origin/main"
FORK_OWNER="y0usaf"
UPSTREAM_REPO="vercel-labs/fx"
FORK_REMOTE="origin"

git fetch "$FORK_REMOTE" --prune >/dev/null

has_upstream_pr() {
  gh pr list --repo "$UPSTREAM_REPO" --state all --head "$FORK_OWNER:$1" \
    --json number --jq 'length' | grep -q '^[1-9]'
}

skip_branch() {
  local b="${1#refs/heads/}"
  case "$b" in refs/backup/*|backup/*|backup-*) return 0 ;; esac
  return 1
}

path_for() {
  local b="${1#refs/heads/}"
  [[ "$b" == "main" || "$b" == "master" ]] && { echo "$WS/main"; return; }
  echo "$WS/${b//\//-}"
}

root="$(git rev-parse --show-toplevel)"
exit_code=0
declared=""

while IFS= read -r branch; do
  b="${branch#refs/heads/}"
  skip_branch "$branch" && continue
  target="$(path_for "$branch")"
  declared="$declared $target "

  if [[ "$b" == main || "$b" == master ]]; then :; elif git merge-base --is-ancestor "$branch" "$MAIN" && ! has_upstream_pr "$b"; then
    if [[ -d "$target/.git" || -f "$target/.git" ]] \
       && [[ -z "$(git -C "$target" status --porcelain)" ]]; then
      echo "DELETE (merged, no upstream PR): $target [$b]"
      if [[ "$APPLY" == 1 && "$PRUNE" == 1 ]]; then
        git worktree remove "$target" && git update-ref -d "refs/heads/$b" || exit_code=1
        continue
      fi
    elif ! git show-ref --verify --quiet "refs/heads/$b" && [[ -e "$target" ]]; then
      : # unreachable; branch existence checked above
    fi
    if [[ "$PRUNE" == 1 && "$APPLY" == 1 ]] \
       && ! git worktree list --porcelain | grep -q "branch refs/heads/$b$"; then
      # orphan: merged branch with no worktree
      echo "DELETE (merged orphan): branch $b"
      git update-ref -d "refs/heads/$b" || exit_code=1
      continue
    fi
    [[ "$PRUNE" == 1 ]] || { echo "KEEP (merged, prune disabled): $target [$b]"; }
  fi

  if [[ -d "$target/.git" || -f "$target/.git" ]]; then
    current="$(git -C "$target" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
    [[ "$current" == "$b" ]] && continue
    echo "MISMATCH: $target has [$current], expected [$b] -- left alone"
    exit_code=1
    continue
  fi
  if [[ -e "$target" ]]; then
    [[ -n "$(ls -A "$target")" ]] && { echo "SKIP (occupied): $target"; continue; }
    [[ "$APPLY" == 1 ]] && rmdir "$target"
  fi
  echo "CREATE: $target [$b]"
  [[ "$APPLY" == 1 ]] && { git worktree add "$target" "$b" || exit_code=1; }
done < <(git for-each-ref --format='%(refname)' refs/heads/)

# Clean worktrees whose branch vanished.
while IFS= read -r wt; do
  [[ "$wt" == "$root" ]] && continue
  case "$wt" in "$WS"/*) ;; *) continue ;; esac
  branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" || {
    echo "SKIP (detached): $wt"; continue;
  }
  git show-ref --verify --quiet "refs/heads/$branch" && continue
  [[ -n "$(git -C "$wt" status --porcelain)" ]] && {
    echo "SKIP (dirty, branch gone): $wt [$branch]"; continue;
  }
  echo "REMOVE (branch gone): $wt [$branch]"
  [[ "$APPLY" == 1 ]] && git worktree remove "$wt" || true
done < <(git worktree list --porcelain | sed -n 's/^worktree //p')

[[ "$APPLY" == 1 ]] || echo "dry-run: pass --apply to execute"
exit "$exit_code"
