#!/usr/bin/env bash
# Rebuild omfx-term.wasm from this checkout and copy it into the site assets.
# Requires nix + zig 0.16.0+.
#
#   site/scripts/sync-wasm.sh [source-repo-path]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$(cd "$ROOT/.." && pwd)}"

cd "$SOURCE"
nix shell nixpkgs#zig --command zig build -Dwasm-surface=term -Doptimize=ReleaseSmall
cp zig-out/bin/omfx-term.wasm "$ROOT/omfx-term.wasm"
echo "synced: $ROOT/omfx-term.wasm ($(stat -c%s "$ROOT/omfx-term.wasm") bytes)"
