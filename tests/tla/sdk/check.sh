#!/bin/sh
set -eu
cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
[ -f "$jar" ] || { echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2; exit 2; }
java=""
for candidate in "${JAVA_HOME:+$JAVA_HOME/bin/java}" /opt/homebrew/opt/openjdk/bin/java /usr/local/opt/openjdk/bin/java "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then java="$candidate"; break; fi
done
[ -n "$java" ] || { echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/libfx-model-tlc.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p graphs
status=0
for tool in send lookup write cutoff leased queue; do
    echo "== DurableSession ($tool)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/$tool" -dump dot,actionlabels "graphs/$tool" \
        -config "DurableSession-$tool.cfg" DurableSession.tla > "$work/$tool.log" 2>&1; then
        cat "$work/$tool.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/$tool.log"
done
for pair in UiInOrder:UiInOrder NoStaleShown:NoStaleShown NotTwoActive:NotTwoActive \
    NoSelfStop:TwoActiveNeedsFreeze NoClaimFence:EffectsAtMostOnce NoCutoffBound:HandoffsBounded \
    LeasedTwoActive:NotTwoActive LookupRunsAhead:EveryCallAfterIntent LookupNewId:IdsAtMostOne \
    WriteRunsAhead:OneExecutionId; do
    witness="${pair%%:*}" invariant="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" DurableSession.tla 2>&1 | grep -q -E "Invariant $invariant is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done
for graph in ideal faults; do
    echo "== DurableSteer ($graph)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/steer-$graph" -dump dot,actionlabels "graphs/steer-$graph" \
        -config "DurableSteer-$graph.cfg" DurableSteer.tla > "$work/steer-$graph.log" 2>&1; then
        cat "$work/steer-$graph.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/steer-$graph.log"
done
for pair in NoInterrupt:NoSteerWaitsOnReply NoHandBack:NothingLost \
    NoJoinBeforeStart:PreStartJoins NoDedupe:AtMostOnce; do
    witness="${pair%%:*}" invariant="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/sw-$witness" \
        -config "SteerWitness-$witness.cfg" DurableSteer.tla 2>&1 | grep -q -E "Invariant $invariant is violated"; then
        echo "== steer witness $witness reached"
    else
        echo "== steer witness $witness NOT reached" >&2; status=1
    fi
done

for config in send; do
    echo "== AgentRouting ($config)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/agents-$config" -dump dot,actionlabels "graphs/agents-$config" \
        -config "AgentRouting-$config.cfg" AgentRouting.tla > "$work/agents-$config.log" 2>&1; then
        cat "$work/agents-$config.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/agents-$config.log"
done
for config in drains-send; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/agents-$config" \
        -config "AgentRouting-$config.cfg" AgentRouting.tla > "$work/agents-$config.log" 2>&1; then
        echo "== AgentRouting ($config): Drains holds"
    else
        cat "$work/agents-$config.log"; status=1
    fi
done
if "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -simulate num=20000 -depth 50 -deadlock -workers auto -cleanup \
    -metadir "$work/agents-sim" -config AgentRouting-sim.cfg AgentRouting.tla > "$work/agents-sim.log" 2>&1; then
    echo "== AgentRouting (simulation): $(grep -E 'states checked' "$work/agents-sim.log" | tail -1)"
else
    cat "$work/agents-sim.log"; status=1
fi
for witness in NoNames NoOwnerCheck; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" AgentRouting.tla 2>&1 | grep -q -E "Invariant RunsOnOwner is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done

echo "== TenantIsolation (route)"
if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
    -metadir "$work/tenants-route" -dump dot,actionlabels graphs/tenants-route \
    -config TenantIsolation-route.cfg TenantIsolation.tla > "$work/tenants-route.log" 2>&1; then
    cat "$work/tenants-route.log"; status=1
else
    grep -E 'distinct states|depth of' "$work/tenants-route.log"
fi
if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/tenants-drains" \
    -config TenantIsolation-drains.cfg TenantIsolation.tla > "$work/tenants-drains.log" 2>&1; then
    echo "== TenantIsolation (drains): SentRuns holds"
else
    cat "$work/tenants-drains.log"; status=1
fi
for pair in "TrustBody:Invariant OnlySentRuns is violated" "ShareName:Invariant RunsOnSenderAgent is violated" \
    "RouteByName:Temporal properties were violated" "NoAdmission:Invariant StoredWithinLimit is violated" \
    "Today:Invariant RunsInSenderStore is violated"; do
    witness="${pair%%:*}" verdict="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/tw-$witness" \
        -config "TenantWitness-$witness.cfg" TenantIsolation.tla 2>&1 | grep -q -F "$verdict"; then
        echo "== tenant witness $witness reached"
    else
        echo "== tenant witness $witness NOT reached" >&2; status=1
    fi
done
exit "$status"
