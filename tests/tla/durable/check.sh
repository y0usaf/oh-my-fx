#!/bin/sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Journal Journal - -deadlock
ToolReplay ToolReplay - -deadlock
ParallelBatch ParallelBatch - -deadlock
Fencing Fencing - -deadlock
Inbox Inbox - -deadlock
Resumption Resumption - -deadlock
SnapshotTail SnapshotTail - -deadlock
EOF
