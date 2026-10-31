#!/bin/sh
set -eu

cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
if [ ! -f "$jar" ]; then
    echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2
    exit 2
fi
java=""
for candidate in \
    "${JAVA_HOME:+$JAVA_HOME/bin/java}" \
    /opt/homebrew/opt/openjdk/bin/java \
    /usr/local/opt/openjdk/bin/java \
    "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then
        java="$candidate"
        break
    fi
done
if [ -z "$java" ]; then
    echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2
    exit 2
fi

all="SessionLog TurnLifecycle WriterLock ResumeSnapshot Fork Subagents Catalog Lifecycle Wiring MoveSideFiles V1Conversion"
specs="${*:-$all}"
work="$(mktemp -d "${TMPDIR:-/tmp}/session-manager-tlc.XXXXXX")"
trap 'rm -rf "$work"' EXIT

status=0
for spec in $specs; do
    echo "== $spec"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -deadlock -workers auto -cleanup \
        -metadir "$work/$spec" \
        -config "$spec.cfg" "$spec.tla"; then
        status=1
    fi
done
exit "$status"
