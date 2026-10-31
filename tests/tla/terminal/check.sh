#!/bin/sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
ShellSnapshot ShellSnapshot -
TerminalLifecycle TerminalLifecycle -
ShellSnapshot ShellSnapshot-reload_per_command DotfilesPaidOnce -deadlock
ShellSnapshot ShellSnapshot-no_single_flight SingleFlight -deadlock
ShellSnapshot ShellSnapshot-free_while_leased NoUseAfterFree -deadlock
ShellSnapshot ShellSnapshot-use_partial RunsCompleteSnapshot -deadlock
ShellSnapshot ShellSnapshot-stale_grant GrantMatchesEpoch -deadlock
ShellSnapshot ShellSnapshot-notice_repeat NoticeOncePerEpisode -deadlock
ShellSnapshot ShellSnapshot-clear_dirty_late FreshWhenClean -deadlock
ShellSnapshot ShellSnapshot-keep_broken NoReuseOfBroken -deadlock
TerminalLifecycle TerminalLifecycle-daemon_survives OrphansOnlyAfterCrash -deadlock
TerminalLifecycle TerminalLifecycle-exit_skips_close OrphansOnlyAfterCrash -deadlock
TerminalLifecycle TerminalLifecycle-profile_wide_recover NoWrongEnd -deadlock
TerminalLifecycle TerminalLifecycle-reattach NoBadInteract -deadlock
EOF
