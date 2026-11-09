#!/bin/bash
# tests/run.sh: the toolkit's own regression tests. Run before every commit.
set -u
# Run from a git hook, git's variables point at the committing repository: the tests' own git calls
# (git -C "$repo" init/add/commit) would act on it. Each git call here names its folder instead.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
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

# The heavy-step guard: its cases; then against fakes, no other machine: this machine's load from a
# file, the peer from an `ssh` on PATH answering from a file ("hang" sleeps, "down" fails).
python3 hooks/heavy-guard.py --test >/dev/null && ok "heavy guard cases" || bad "heavy guard cases: $(python3 hooks/heavy-guard.py --test)"
hg=$(mktemp -d); mkdir -p "$hg/bin" "$hg/home/.claude" "$hg/wt/sub"
printf '#!/bin/bash\necho x >> %s/ssh-calls\na=$(cat %s/peer)\n[ "$a" = hang ] && exec sleep 31.7\n[ "$a" = down ] && exit 255\nprintf "%%s\\n" $a\n' "$hg" "$hg" > "$hg/bin/ssh"
chmod 755 "$hg/bin/ssh"
hgrig() {  # hgrig LOAD PEER-ANSWER: a fresh state, the example config installed
    echo "$1 1.00 1.00 1/100 1" > "$hg/loadavg"; echo "$2" > "$hg/peer"
    rm -f "$hg/ssh-calls" "$hg/home/.claude/heavy-guard-load.json" "$hg/home/.claude/toolkit-hits.log"
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c.pop("cases"); json.dump(c, open(sys.argv[2], "w"))' \
        hooks/heavy-guard.cases.json "$hg/home/.claude/heavy-guard.json"
}
hgrun() {  # hgrun COMMAND [ENV=VALUE...]: the hook's exit code; its message in $hg/err
    local c=$1; shift
    python3 -c 'import json,sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$c" "$hg/wt" |
        env -u HEAVY_LOCAL PATH="$hg/bin:$PATH" HOME="$hg/home" HEAVY_GUARD_LOADAVG="$hg/loadavg" HEAVY_GUARD_CORES=32 "$@" \
        python3 hooks/heavy-guard.py 2>"$hg/err"; echo $?
}
hgcalls() { [ -f "$hg/ssh-calls" ] && wc -l < "$hg/ssh-calls" | tr -d ' ' || echo 0; }
# Busy here (20 + 16 threads on 32 cores) and the peer idle: blocked, the line that runs it there
# named, the block logged.
hgrig 20 "0.10 16"
[ "$(hgrun "cargo test --release")" = 2 ] && grep -qF "build-box sits at 0.01" "$hg/err" \
    && grep -qF "ssh build-box 'cd $hg/wt && cargo test --release'" "$hg/err" \
    && grep -qF "HEAVY_LOCAL=1 cargo test --release" "$hg/err" \
    && grep -q "	heavy-guard	cargo-release$" "$hg/home/.claude/toolkit-hits.log" \
    && ok "heavy guard: busy here, peer idle: blocked with the line, logged" || bad "heavy guard block: $(cat "$hg/err")"
# A leading cd decides the directory.
[ "$(hgrun "cd sub && npm test")" = 2 ] && grep -qF "ssh build-box 'cd $hg/wt/sub && npm test'" "$hg/err" \
    && ok "heavy guard: a leading cd is where it runs" || bad "heavy guard leading cd: $(cat "$hg/err")"
# This machine with room: allowed, and the peer isn't asked.
hgrig 1 "0.10 16"
[ "$(hgrun "cargo test --release")" = 0 ] && [ "$(hgcalls)" = 0 ] \
    && ok "heavy guard: room here: allowed, no probe" || bad "heavy guard idle local ($(hgcalls) probes)"
# The override, in the command or the environment.
hgrig 20 "0.10 16"
[ "$(hgrun "HEAVY_LOCAL=1 npm test")" = 0 ] && [ "$(hgrun "export HEAVY_LOCAL=1; cargo test --release")" = 0 ] \
    && [ "$(hgrun "npm test" HEAVY_LOCAL=1)" = 0 ] && ok "heavy guard: HEAVY_LOCAL=1 allows" || bad "heavy guard override"
# Already elsewhere: through the configured runner, or inside ssh HOST '...'.
[ "$(hgrun "my-runner -- npm test")" = 0 ] && [ "$(hgrun "ssh build-box 'cargo test --release'")" = 0 ] \
    && ok "heavy guard: via the runner or ssh: allowed" || bad "heavy guard runner/ssh"
# Light commands and text that only names a heavy step.
r=0; for c in "ls -la" "cargo test" "npm run build" "git commit -m 'npm test passes'" "echo npm test"; do
    [ "$(hgrun "$c")" = 0 ] || r=1; done
[ $r = 0 ] && ok "heavy guard: light commands allowed" || bad "heavy guard light commands"
# No config at all: everything allowed, nothing probed.
rm "$hg/home/.claude/heavy-guard.json"
[ "$(hgrun "cargo test --release")" = 0 ] && [ "$(hgcalls)" = 0 ] \
    && ok "heavy guard: no config: allowed, no probe" || bad "heavy guard without config"
# The peer unreachable: allowed.
hgrig 20 down
[ "$(hgrun "npm test")" = 0 ] && ok "heavy guard: peer unreachable: allowed" || bad "heavy guard peer down"
# A peer that hangs: the probe is bounded (a timeout check, not a time budget: supervise.sh's
# deadline of 3 s against the guard's 1.5 s), nothing of it outlives the hook, and its silence is
# cached (one probe for two commands).
hgrig 20 hang
echo '{"tool_input":{"command":"npm test"},"cwd":"/"}' > "$hg/payload"   # (supervise.sh gives the job no stdin)
hang() { env -u HEAVY_LOCAL PATH="$hg/bin:$PATH" HOME="$hg/home" HEAVY_GUARD_LOADAVG="$hg/loadavg" HEAVY_GUARD_CORES=32 \
    bin/supervise.sh --deadline 3 -- bash -c 'python3 hooks/heavy-guard.py < "$1"' _ "$hg/payload" 2>/dev/null; echo $?; }
[ "$(hang)" = 0 ] && [ "$(hang)" = 0 ] && [ "$(hgcalls)" = 1 ] && ! bin/procs.sh count "sleep 31.7" >/dev/null \
    && ok "heavy guard: a hanging peer is cut off, once" || bad "heavy guard hanging peer ($(hgcalls) probes)"
rm -rf "$hg"

# statusline.sh keeps Claude Code's feed and shows the plan's usage; usage-advisor.py reads it, and
# for a risky task already failed once picks a higher effort than for a mechanical one.
sl=$(mktemp -d)
feed='{"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":9,"resets_at":4102444800},"seven_day":{"used_percentage":85,"resets_at":4102444800}},"model":{"display_name":"Opus"},"effort":{"level":"medium"}}'
line=$(printf '%s' "$feed" | HOME="$sl" bin/statusline.sh)
echo "$line" | grep -q "5h 9% · 7d 85% · Opus · medium" && [ -s "$sl/.cache/claude-statusline.json" ] \
    && ok "statusline shows the usage and keeps the feed" || bad "statusline: $line"
out=$(HOME="$sl" python3 bin/usage-advisor.py)
echo "$out" | grep -q "85% used,  15% left" && ok "usage-advisor reads the feed" || bad "usage-advisor: $out"
lo=$(HOME="$sl" python3 bin/usage-advisor.py --risk low | sed -n 's|.*/effort \([a-z]*\).*|\1|p')
hi=$(HOME="$sl" python3 bin/usage-advisor.py --risk high --tries 1 | sed -n 's|.*/effort \([a-z]*\).*|\1|p')
rank() { case $1 in low) echo 0;; medium) echo 1;; high) echo 2;; xhigh) echo 3;; max) echo 4;; *) echo -1;; esac; }
[ "$(rank "$hi")" -gt "$(rank "$lo")" ] && [ "$(rank "$lo")" -ge 0 ] \
    && ok "usage-advisor prices in retries ($lo for a low risk, $hi for a high one tried before)" || bad "usage-advisor picks: $lo / $hi"
rm -rf "$sl"

tests/sanitize.sh || fail=1

[ $fail = 0 ] && echo "all passed" || { echo "failures"; exit 1; }
