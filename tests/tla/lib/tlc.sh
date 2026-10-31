# shellcheck shell=sh

tlc_find() {
    tlc_jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
    if [ ! -f "$tlc_jar" ]; then
        echo "tla2tools.jar not found at $tlc_jar (set TLA2TOOLS_JAR)" >&2
        exit 2
    fi
    tlc_java=""
    for candidate in \
        "${JAVA_HOME:+$JAVA_HOME/bin/java}" \
        /opt/homebrew/opt/openjdk/bin/java \
        /usr/local/opt/openjdk/bin/java \
        "$(command -v java 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then
            tlc_java="$candidate"
            break
        fi
    done
    if [ -z "$tlc_java" ]; then
        echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2
        exit 2
    fi
}

tlc_verdicts() {
    tlc_find
    tlc_work="$(mktemp -d "${TMPDIR:-/tmp}/fx-tla-$(basename "$(pwd)").XXXXXX")" || {
        echo "cannot create a private folder under ${TMPDIR:-/tmp}" >&2
        exit 2
    }
    echo "logs: $tlc_work"
    tlc_status=0
    tlc_ran=""
    while read -r spec config expect flags; do
        case "$spec" in '' | '#'*) continue ;; esac
        if [ "$#" -gt 0 ]; then
            case " $* " in *" $config "*) ;; *) continue ;; esac
        fi
        tlc_ran="$tlc_ran $config"
        log="$tlc_work/$config.log"
        mkdir -p "$tlc_work/$config.tmp"
        # shellcheck disable=SC2086
        if "$tlc_java" -XX:+UseParallelGC -Xss4m "-Djava.io.tmpdir=$tlc_work/$config.tmp" -cp "$tlc_jar" tlc2.TLC \
            -workers auto -cleanup -metadir "$tlc_work/$config.states" \
            $flags -config "$config.cfg" "$spec.tla" >"$log" 2>&1; then
            code=0
        else
            code=$?
        fi
        case "$expect" in
        -)
            if [ "$code" -eq 0 ] && grep -q "No error has been found" "$log"; then
                echo "ok    $config: no error"
                continue
            fi
            ;;
        temporal)
            if grep -q "Temporal properties were violated" "$log"; then
                echo "ok    $config: temporal property violated, as required"
                continue
            fi
            ;;
        simulate)
            if [ "$code" -eq 0 ] && ! grep -q "^Error:" "$log"; then
                echo "ok    $config: simulation found no error"
                continue
            fi
            ;;
        deadlock)
            if grep -q "Deadlock reached" "$log"; then
                echo "ok    $config: deadlock reached, as required"
                continue
            fi
            ;;
        *)
            if grep -q -E "(Invariant|Action property) $expect is violated" "$log"; then
                echo "ok    $config: $expect violated, as required"
                continue
            fi
            ;;
        esac
        echo "FAIL  $config: expected $expect, TLC exited $code (see $log)"
        tlc_status=1
    done
    for wanted in "$@"; do
        case "$tlc_ran " in *" $wanted "*) ;; *)
            echo "FAIL  $wanted: no such config"
            tlc_status=1
            ;;
        esac
    done
    return "$tlc_status"
}
