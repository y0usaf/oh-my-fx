#!/bin/sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

if [ "$#" -eq 0 ]; then
    set -- LeanUsageSmall LeanUsageDrive Ideal Hostile HostileSwitch
fi
tlc_verdicts "$@" <<'EOF'
LeanUsage LeanUsageSmall -
LeanUsage LeanUsage -
LeanUsageDrive LeanUsageDrive - -deadlock
UsageModel Ideal -
UsageModel Hostile -
UsageModel HostileSwitch -
EOF
