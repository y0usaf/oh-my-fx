#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

personal_paths="$({
  git grep -n -E '/Users/[^/[:space:]]+/' -- . ':(exclude)scripts/check-public-surface.sh' || true
} | grep -Ev '/Users/(example|tester|private|me|<you>)/' || true)"
if [[ -n "$personal_paths" ]]; then
  printf 'Tracked personal paths found:\n%s\n' "$personal_paths" >&2
  exit 1
fi

real_team_ids="$({
  git grep -n -E 'team_[A-Za-z0-9]{24}' -- . ':(exclude)scripts/check-public-surface.sh' || true
} | grep -Fv 'team_000000000000000000000000' || true)"
if [[ -n "$real_team_ids" ]]; then
  printf 'Tracked real-looking team identifiers found:\n%s\n' "$real_team_ids" >&2
  exit 1
fi

internal_slugs="$(git grep -n -E 'vercel-internal-[a-z0-9-]+' -- . ':(exclude)scripts/check-public-surface.sh' || true)"
if [[ -n "$internal_slugs" ]]; then
  printf 'Tracked internal team slugs found:\n%s\n' "$internal_slugs" >&2
  exit 1
fi

personal_project_slugs="$(git grep -n -E '[a-z]+-[0-9]+s-projects' -- . ':(exclude)scripts/check-public-surface.sh' || true)"
if [[ -n "$personal_project_slugs" ]]; then
  printf 'Tracked personal project slugs found:\n%s\n' "$personal_project_slugs" >&2
  exit 1
fi

