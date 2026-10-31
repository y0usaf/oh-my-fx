#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: run-tlc.sh <Module.tla> <Config.cfg> [TLC args...]" >&2
    exit 2
fi
# shellcheck source=tlc.sh
. "$(dirname "$0")/tlc.sh"
tlc_find

spec="$1"
cfg="$2"
shift 2
[ -f "$spec" ] || { echo "run-tlc.sh: spec not found: $spec" >&2; exit 2; }
[ -f "$cfg" ] || { echo "run-tlc.sh: config not found: $cfg" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/fx-tlc.XXXXXX")"
mkdir -p "$work/model" "$work/tmp" "$work/states"
cp "$(dirname "$spec")"/*.tla "$work/model/"
cp "$cfg" "$work/model/"

echo "run-tlc.sh: java=$tlc_java jar=$tlc_jar work=$work" >&2
set +e
(
    cd "$work/model" &&
        "$tlc_java" -XX:+UseParallelGC -Xmx512m "-Djava.io.tmpdir=$work/tmp" -cp "$tlc_jar" tlc2.TLC \
            -workers 1 -metadir "$work/states" -config "$(basename "$cfg")" "$@" "$(basename "$spec")"
)
status=$?
set -e

[ "${KEEP_TLC_WORK:-0}" = "1" ] || rm -rf "$work"
exit "$status"
