#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/update-rush.sh [--check] [REVISION]

Rebuilds vendor/rush from upstream rush at REVISION, copying the paths in
vendor/rush-patches/FILES and applying vendor/rush-patches/*.patch in order.
Without REVISION it uses vendor/rush-patches/REVISION. A successful update
writes the revision back to that file.

  --check   rebuild into a temporary directory and fail if vendor/rush
            differs, without changing anything

Set RUSH_SOURCE to a local rush checkout or source tree at REVISION to skip
the network fetch. Set RUSH_URL to fetch from another remote.
EOF
}

check=false
revision=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *) revision="$1" ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

patch_dir="vendor/rush-patches"
vendor_dir="vendor/rush"
revision="${revision:-$(tr -d '[:space:]' < "$patch_dir/REVISION")}"
rush_url="${RUSH_URL:-https://github.com/rockorager/rush.git}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "${RUSH_SOURCE:-}" ]]; then
  source_dir="$RUSH_SOURCE"
else
  source_dir="$work/upstream"
  git init -q "$source_dir"
  git -C "$source_dir" fetch -q --depth 1 "$rush_url" "$revision"
  git -C "$source_dir" checkout -q FETCH_HEAD
fi

tree="$work/tree"
mkdir -p "$tree"
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ ! -e "$source_dir/$path" ]]; then
    printf 'update-rush: %s is missing from rush %s\n' "$path" "$revision" >&2
    exit 1
  fi
  mkdir -p "$tree/$(dirname "$path")"
  cp -R "$source_dir/$path" "$tree/$path"
done < "$patch_dir/FILES"
chmod -R u+w "$tree"

for patch in "$patch_dir"/*.patch; do
  if ! (cd "$tree" && git apply --whitespace=nowarn "$repo_root/$patch"); then
    printf 'update-rush: %s no longer applies to rush %s\n' "$patch" "$revision" >&2
    exit 1
  fi
done

if [[ "$check" == true ]]; then
  if ! diff -r "$tree" "$vendor_dir" >&2; then
    printf 'update-rush: %s does not match rush %s plus %s; run scripts/update-rush.sh\n' \
      "$vendor_dir" "$revision" "$patch_dir" >&2
    exit 1
  fi
  printf 'update-rush: %s matches rush %s plus %d patches\n' \
    "$vendor_dir" "$revision" "$(find "$patch_dir" -name '*.patch' | wc -l)"
  exit 0
fi

rm -rf "$vendor_dir"
mv "$tree" "$vendor_dir"
printf '%s\n' "$revision" > "$patch_dir/REVISION"
printf 'update-rush: %s rebuilt from rush %s\n' "$vendor_dir" "$revision"
