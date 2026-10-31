#!/bin/sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Refresh refresh - -deadlock
Refresh refresh-simulation - -deadlock
Refresh refresh-mutation NoStalePublication -deadlock
RefreshWitness refresh-witness-NoReuse NoReuse -deadlock
RefreshWitness refresh-witness-NoReuseAfterEdit NoReuseAfterEdit -deadlock
RefreshWitness refresh-witness-NoReuseAfterIgnore NoReuseAfterIgnore -deadlock
RefreshWitness refresh-witness-NoEditAfterReuse NoEditAfterReuse -deadlock
RefreshWitness refresh-witness-NoIgnoreChangeAfterReuse NoIgnoreChangeAfterReuse -deadlock
GrepCut grep-cut - -deadlock
GrepCut grep-cut-mutation-order MergeCorrect -deadlock
GrepCut grep-cut-mutation-oom MergeCorrect -deadlock
ListingWait listing-wait - -deadlock
ListingWait listing-wait-mutation NoFlashUnlessSlow -deadlock
SnapshotSources snapshot-contract - -deadlock
SnapshotSources snapshot-implementation - -deadlock
SnapshotSources snapshot-mutation-ancestors NoStaleReuse -deadlock
SnapshotSources snapshot-mutation-follow NoStaleReuse -deadlock
SnapshotSources snapshot-mutation-key NoStaleReuse -deadlock
EOF
