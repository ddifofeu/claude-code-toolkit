#!/bin/bash
# procs.sh: find or signal processes by command-line pattern, safely.
#
#   procs.sh list  PATTERN            matching processes: PID and command line
#   procs.sh count PATTERN            how many (exit 1 when none)
#   procs.sh kill [-SIG] PATTERN      signal them (default TERM); exit 1 when none
#   procs.sh alive PID...             exit 0 when every PID is running
#
# On another machine (nothing to install there):
#   ssh HOST bash -s -- kill my_worker.py < procs.sh
#
# Why not pgrep/pkill -f: they match every full command line, including the shell that
# runs them (`bash -c "... pkill -f PATTERN"` contains PATTERN), so they kill or count their
# own caller; over ssh they kill the remote shell. This never matches the caller or its
# parents, shells, ssh, or itself: only the actual programs (python, node, adb, ...).
# PATTERN is an extended regex matched against the command line (arguments joined by spaces).
# --shells also matches shell processes (for a job whose own program is a shell script),
# still never the caller's parents.
set -u
usage() { sed -n '2,8p' "${BASH_SOURCE[0]:-procs.sh}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 2; }

shells=0
[ "${1:-}" = --shells ] && { shells=1; shift; }
cmd=${1:-}; shift || true

# The caller and every ancestor up to init.
declare -A skip=()
p=$$
while [ -n "$p" ] && [ "$p" != 0 ]; do
    skip[$p]=1
    p=$(awk '/^PPid:/ {print $2}' /proc/$p/status 2>/dev/null)
done

matches() {  # matches PATTERN: prints "PID<TAB>command line" for each match
    local pat=$1 dir pid comm args
    for dir in /proc/[0-9]*; do
        pid=${dir#/proc/}
        [ -n "${skip[$pid]:-}" ] && continue
        args=$({ tr '\0' ' ' < "$dir/cmdline"; } 2>/dev/null) || continue  # { }: the shell reports a failed < itself
        [ -z "$args" ] && continue                      # kernel threads
        comm=$(cat "$dir/comm" 2>/dev/null) || continue
        case "$comm" in
            ssh|sshd|sudo) continue ;;
            bash|sh|dash|zsh|fish) [ $shells = 1 ] || continue ;;
        esac
        case "$args" in *procs.sh*) continue ;; esac
        printf '%s\n' "$args" | grep -qE -- "$pat" && printf '%s\t%s\n' "$pid" "${args% }"
    done
}

case "$cmd" in
    list)  [ $# = 1 ] || usage; matches "$1" ;;
    count) [ $# = 1 ] || usage; n=$(matches "$1" | wc -l); echo "$n"; [ "$n" -gt 0 ] ;;
    kill)
        sig=TERM
        case "${1:-}" in -*) sig=${1#-}; shift ;; esac
        [ $# = 1 ] || usage
        found=$(matches "$1")
        [ -z "$found" ] && { echo "no process matches: $1" >&2; exit 1; }
        while IFS=$'\t' read -r pid args; do
            kill -s "$sig" "$pid" 2>/dev/null && echo "$sig $pid $args" || echo "could not signal $pid $args" >&2
        done <<< "$found" ;;
    alive)
        [ $# -ge 1 ] || usage
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null || exit 1; done ;;
    *) usage ;;
esac
