#!/bin/sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
LaunchSelection proposed -
LaunchSelection current-holds -
LaunchSelection current-model ValidModel
LaunchSelection current-speed HonestSpeed
LaunchSelection current-effort HonestEffort
LaunchSelection current-late-error AskFailsEarly
LaunchSelection current-canonical Canonical
LaunchSelection mutant-reject-weak NoFalseReject
LaunchSelection mutant-no-canonical Canonical
LaunchSelection mutant-block-frame FirstFrameNotBlocked
LaunchSelection mutant-persist SettingsUntouched
LaunchSelection mutant-silent CorrectionsAnnounced
LaunchSelection simulate-ideal simulate $sim
LaunchSelection simulate-nonideal simulate $sim
EOF
