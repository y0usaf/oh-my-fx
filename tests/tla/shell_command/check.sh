#!/bin/sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
GitAdmission git-admission - -deadlock
GitAdmission git-admission-mutation HoldSafety -deadlock
ShellContract proposed -
ShellContract current-holds -
ShellContract current-completeness Completeness
ShellContract current-history HistoryFidelity
ShellContract current-zsh ZshForgiving
ShellContract mutant-admission-raw AdmissionConsistency
ShellContract mutant-guess Exactness
EOF
