#!/bin/bash
# tests/run.sh: the toolkit's own regression tests. Run before every commit.
set -u
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

# The guard: every saved case.
python3 hooks/bash-guards.py --test >/dev/null && ok "guard cases" || bad "guard cases: $(python3 hooks/bash-guards.py --test)"

# procs.sh finds a target whose marker is also in this script's own command line, kills only it.
marker="procs-test-$$"
python3 -c "import time; time.sleep(60)" "$marker" & target=$!
sleep 0.3
[ "$(bin/procs.sh count "$marker")" = 1 ] && ok "procs count" || bad "procs count"
bin/procs.sh kill "$marker" >/dev/null && ok "procs kill" || bad "procs kill"
wait $target 2>/dev/null
bin/procs.sh alive $target && bad "procs: target still alive" || ok "procs: target gone, caller alive"
# A process that exits mid-scan: the shell itself reports a failed `< /proc/PID/...` unless the
# redirect sits inside { } 2>/dev/null (it printed "No such file or directory" lines).
grep -n '< "\$dir/' bin/procs.sh | grep -qv '{ ' && bad "procs: unguarded /proc redirect" || ok "procs: quiet when a process exits mid-scan"

# The tracker: a good entry passes, and each kind of bad entry fails.
repo=$(mktemp -d); trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q
mkdir -p "$repo/tracker" "$repo/tests"; echo 'def test_x(): assert True' > "$repo/tests/test_x.py"
entry() { printf '# T-%s %s\nkind: bug\nstatus: %s\nreported: 2026-01-01, test\nblocker: %s\ntest: %s\nfixed-in: %s\n' "$@" > "$repo/tracker/T-$1-x.md"; }
check() { (cd "$repo" && python3 "$OLDPWD/tracker/tracker.py" check >/dev/null); }
entry 001 Good fixed - "tests/test_x.py::test_x" abc123
check && ok "tracker: good entry" || bad "tracker: good entry rejected"
for broken in "002 NoTest fixed - - abc" "003 MissingTest fixed - tests/nope.py abc" \
              "004 NoBlocker blocked - - -" "005 WrongText fixed - tests/test_x.py::test_y abc"; do
    entry $broken; check && bad "tracker accepts: $broken" || ok "tracker rejects: ${broken#* }"
    rm "$repo/tracker/T-${broken%% *}-x.md"
done

# A new entry's number skips those used on other branches and in other worktrees (two branches
# worked side by side handed out the same number).
r2=$(mktemp -d); git -C "$r2" init -q; git -C "$r2" config user.email t@t; git -C "$r2" config user.name t
mkdir -p "$r2/tracker"; entry2() { printf '# T-%s x\nkind: bug\nstatus: open\nreported: 2026-01-01, t\nblocker: -\ntest: -\nfixed-in: -\n' "$1" > "$2/tracker/T-$1-x.md"; }
entry2 001 "$r2"; git -C "$r2" add -A; git -C "$r2" commit -qm a
git -C "$r2" checkout -qb side; entry2 004 "$r2"; git -C "$r2" add -A; git -C "$r2" commit -qm b; git -C "$r2" checkout -q -
git -C "$r2" worktree add -q "$r2-wt" -b other 2>/dev/null; entry2 006 "$r2-wt"
out=$(cd "$r2" && python3 "$OLDPWD/tracker/tracker.py" new bug "Next" t)
[ "${out#tracker/T-007}" != "$out" ] && ok "tracker: new number past other branches and worktrees" || bad "tracker numbering: $out"
rm -rf "$r2" "$r2-wt"

# The guard logs each block (for pruning guards that never fire), and never fails without a log.
home=$(mktemp -d); mkdir -p "$home/.claude"
echo '{"tool_input":{"command":"pkill -f x"}}' | HOME=$home python3 hooks/bash-guards.py 2>/dev/null
[ $? = 2 ] && grep -q "bash-guards	pkill" "$home/.claude/toolkit-hits.log" && ok "guard logs its blocks" || bad "guard hit log"
rm -rf "$home"

# The pre-commit framework hook points at an executable tracker.
grep -q "entry: tracker/tracker.py check" .pre-commit-hooks.yaml && [ -x tracker/tracker.py ] \
    && ok "pre-commit framework hook" || bad "pre-commit framework hook"

# The repo hook for web sessions: guards there (CLAUDE_CODE_REMOTE=true), does nothing locally,
# where the user-level hook already runs, and nothing when the guard isn't installed.
home=$(mktemp -d); mkdir -p "$home/.claude/hooks"; cp hooks/bash-guards.py "$home/.claude/hooks/"
cmd=$(python3 -c 'import json; print(json.load(open("cloud/repo-settings.json"))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])')
web() { echo '{"tool_input":{"command":"pkill -f x"}}' | HOME=$1 CLAUDE_CODE_REMOTE=$2 bash -c "$cmd" 2>/dev/null; echo $?; }
[ "$(web "$home" true)" = 2 ] && [ "$(web "$home" "")" = 0 ] && [ "$(web "$(mktemp -d)" true)" = 0 ] \
    && ok "repo hook for web sessions" || bad "repo hook for web sessions"
rm -rf "$home"

# The promise guard: its cases; it sends a promise back once (logged), lets the second stop through.
python3 hooks/promise-guard.py --test >/dev/null && ok "promise guard cases" || bad "promise guard cases: $(python3 hooks/promise-guard.py --test)"
home=$(mktemp -d); mkdir -p "$home/.claude"
stop() { echo "{\"stop_hook_active\":$1,\"last_assistant_message\":\"Done. I'll start the next run now.\"}" | HOME=$home python3 hooks/promise-guard.py; }
stop false | grep -q '"decision": "block"' && grep -q "promise-guard" "$home/.claude/toolkit-hits.log" && [ -z "$(stop true)" ] \
    && ok "promise guard blocks once and logs" || bad "promise guard blocks once and logs"
rm -rf "$home"

# budget-scan: a test's time budget on the wall clock is flagged (JS and Python), CPU time and a
# marked real wall-clock check are not.
d=$(mktemp -d)
printf 'const t0 = performance.now();\nwork();\nassert.ok(performance.now() - t0 < 2000);\n' > "$d/wall.test.mjs"
printf 'start = time.perf_counter()\nwork()\nelapsed = time.perf_counter() - start\nassert elapsed < 2\n' > "$d/test_wall.py"
printf 'const c0 = process.cpuUsage();\nwork();\nconst u = process.cpuUsage(c0);\nassert.ok((u.user + u.system) / 1000 < 2000);\n' > "$d/cpu.test.mjs"
printf 'const t0 = Date.now();\nawait reply();\nassert.ok(Date.now() - t0 < 5000); // wall-clock-ok: a timeout\n' > "$d/marked.test.mjs"
out=$(python3 bin/budget-scan.py "$d"); code=$?
[ $code = 1 ] && echo "$out" | grep -q "wall.test.mjs:3" && echo "$out" | grep -q "test_wall.py:4" \
    && ! echo "$out" | grep -q "cpu.test.mjs" && ! echo "$out" | grep -q "marked.test.mjs" \
    && ok "budget-scan flags wall-clock budgets only" || bad "budget-scan: $out"
rm -f "$d/wall.test.mjs" "$d/test_wall.py"
python3 bin/budget-scan.py "$d" >/dev/null && ok "budget-scan passes clean tests" || bad "budget-scan on clean tests"
rm -rf "$d"

# supervise.sh: the job's code passes through; past the deadline 124; nothing of it outlives it, a
# detached (setsid) grandchild included; a TERM to the supervisor takes the job down too.
m="supervise-test-$$"
bin/supervise.sh -- bash -c 'exit 3'; [ $? = 3 ] && ok "supervise: exit code" || bad "supervise: exit code"
d=$(mktemp -d)
bin/supervise.sh --deadline 1 --exit "$d/x" -- bash -c "setsid python3 -c \"import time; time.sleep(60)\" $m-a & python3 -c \"import time; time.sleep(60)\" $m-b"; c=$?
[ $c = 124 ] && read -r e _ < "$d/x" && [ "$e" = 124 ] && ok "supervise: deadline 124, exit file" || bad "supervise: deadline ($c)"
bin/procs.sh count "$m-[ab]" >/dev/null && bad "supervise: left $(bin/procs.sh list "$m-[ab]")" || ok "supervise: nothing left, detached child included"
bin/supervise.sh -- bash -c "setsid python3 -c \"import time; time.sleep(60)\" $m-c & python3 -c \"import time; time.sleep(60)\" $m-d" & s=$!
sleep 0.5; kill -TERM $s; wait $s; c=$?
[ $c = 143 ] && ! bin/procs.sh count "$m-[cd]" >/dev/null && ok "supervise: TERM takes the job down" || bad "supervise: TERM ($c)"
bin/procs.sh kill "$m-" >/dev/null 2>&1; rm -rf "$d"

tests/sanitize.sh || fail=1

[ $fail = 0 ] && echo "all passed" || { echo "failures"; exit 1; }
