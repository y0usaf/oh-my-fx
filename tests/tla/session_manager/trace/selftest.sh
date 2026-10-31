#!/bin/sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/session-manager-selftest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

python3 "$here/stand_in_log.py" "$tmp/good.log" "$tmp/good.ndjson"
python3 "$here/stand_in_log.py" "$tmp/bad.log" "$tmp/bad.ndjson" keep_torn_tail
sed '5s/"acked": 2/"acked": 3/' "$tmp/good.ndjson" > "$tmp/tampered.ndjson"

failures=0
expect() {
    set +e
    got=$("$here/validate.sh" SessionLog "$2" 2>&1)
    code=$?
    set -e
    if [ "$code" -eq "$3" ] && printf '%s' "$got" | grep -q "$4"; then
        echo "ok    $1: $(printf '%s' "$got" | head -1)"
    else
        echo "FAIL  $1: exit $code, wanted $3 and '$4'"
        printf '%s\n' "$got" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
}

expect "correct implementation" "$tmp/good.ndjson" 0 "ACCEPTED"
expect "recovery keeps a torn tail" "$tmp/bad.ndjson" 1 "step 8 of"
expect "tampered acked field" "$tmp/tampered.ndjson" 1 "step 5 of"

if [ "$failures" -eq 0 ]; then
    echo "trace selftest passed"
    exit 0
fi
echo "trace selftest failed: $failures case(s)"
exit 1
