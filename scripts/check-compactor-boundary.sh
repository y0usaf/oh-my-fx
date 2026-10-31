#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/compactor"

reaching_in="$({
  git grep -n -E '@import\("[^"]*compactor/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'compactor/compactor\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/compactor.zig may be imported from outside the compactor:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

allowed='^\.\./(shared/(types|debug_trace|token_estimate|text_utils|io|history_range|testing_allocator)|config/(model_capabilities|model_provider))\.zig$'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep -n -o -E '@import\("\.\./[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The compactor may import only shared basics; hand anything else in through its API:\n%s' "$reaching_out" >&2
  exit 1
fi
