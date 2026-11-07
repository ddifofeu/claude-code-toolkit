#!/bin/bash
# supervise.sh: run a job so that nothing of it outlives it.
#
#   supervise.sh [--deadline SECONDS] [--exit FILE] -- COMMAND [ARGS...]
#
# The job runs in a process group of its own, marked in its environment (SUPERVISE_JOB). However it
# ends (it exits, it passes the deadline, or the supervisor gets TERM, INT or HUP), the supervisor
# kills the group and then every process still carrying the mark, then exits with the job's code
# (124 past the deadline). --exit FILE also writes "CODE EPOCH" there, atomically, once nothing is
# left: a watcher that sees the file knows the job is fully gone.
#
# Why: a job's children outlive it. A test server, a headless browser or a worker started by a
# script survives the script's end or its kill, holds a port, a GPU or memory, and breaks the next
# run. Killing the process group misses whatever left it: browsers are often started detached
# (setsid). They can't leave their environment, so the mark finds them (Linux /proc; elsewhere only
# the group is killed).
set -u
deadline=0 exitfile=
while [ $# -gt 0 ]; do
    case $1 in
        --deadline) deadline=$2; shift 2 ;;
        --exit) exitfile=$2; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

set -m
mark="supervise-$$-$RANDOM$RANDOM"
marked() { [ -d /proc ] && grep -lzxF "SUPERVISE_JOB=$mark" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 | grep -vx "$$"; }
sweep() {
    for sig in TERM KILL; do
        [ -n "${J:-}" ] && kill -$sig -- -"$J" 2>/dev/null
        p=$(marked); [ -n "$p" ] && kill -$sig $p 2>/dev/null
        for _ in $(seq 25); do
            { [ -n "${J:-}" ] && kill -0 -- -"$J" 2>/dev/null; } || [ -n "$(marked)" ] || return 0
            sleep 0.2
        done
    done
}
J=
trap 'sweep; exit 143' TERM INT HUP
SUPERVISE_JOB=$mark "$@" < /dev/null &
J=$!
W=
if [ "$deadline" -gt 0 ]; then
    ( sleep "$deadline"; touch "${TMPDIR:-/tmp}/.supervise-$mark.late"; kill -TERM -- -"$J" 2>/dev/null ) > /dev/null 2>&1 &
    W=$!
fi
{ wait "$J"; } 2>/dev/null; code=$?
[ -n "$W" ] && { kill -KILL -- -"$W" 2>/dev/null; wait "$W" 2>/dev/null; }
[ -e "${TMPDIR:-/tmp}/.supervise-$mark.late" ] && { code=124; rm -f "${TMPDIR:-/tmp}/.supervise-$mark.late"; }
sweep
if [ -n "$exitfile" ]; then echo "$code $(date +%s)" > "$exitfile.tmp" && mv "$exitfile.tmp" "$exitfile"; fi
exit "$code"
