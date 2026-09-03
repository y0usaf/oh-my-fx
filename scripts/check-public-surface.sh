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

capture='tests/e2e/fixtures/fx-render-bug-20260510-075848.tar.gz'
archive_listing="$(tar -tzvf "$capture")"
unexpected_owners="$(grep -Ev '[[:space:]]root([/]|[[:space:]]+)root[[:space:]]' <<<"$archive_listing" || true)"
if [[ -n "$unexpected_owners" ]]; then
  printf 'Render fixture archive metadata contains a non-root owner:\n%s\n' "$unexpected_owners" >&2
  exit 1
fi
if grep -Eq '/\._' <<<"$archive_listing"; then
  printf 'Render fixture contains macOS AppleDouble metadata\n' >&2
  exit 1
fi

extract_dir="$(mktemp -d)"
trap 'rm -rf "$extract_dir"' EXIT
tar -xzf "$capture" -C "$extract_dir"

archive_matches="$({
  grep -R -a -n -E '/Users/[^/[:space:]]+/|team_[A-Za-z0-9]{24}' "$extract_dir" || true
} | grep -Ev '/Users/(guest|example|tester|private|me)/|team_000000000000000000000000' || true)"
if [[ -n "$archive_matches" ]]; then
  printf 'Render fixture contains personal or internal data:\n%s\n' "$archive_matches" >&2
  exit 1
fi

if ! grep -R -a -q 'sanitized-v1' "$extract_dir"; then
  printf 'Render fixture is missing its sanitized branch marker\n' >&2
  exit 1
fi
