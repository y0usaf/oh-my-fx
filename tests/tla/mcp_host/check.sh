#!/bin/sh
set -eu

cd "$(dirname "$0")"
out="$(mktemp -d "${TMPDIR:-/tmp}/fx-tla-mcp_host.XXXXXX")"
exec bun ../drivers/mcp_host/model.ts "$out" "$@"
