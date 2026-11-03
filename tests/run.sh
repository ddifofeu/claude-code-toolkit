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

# The guard logs each block (for pruning guards that never fire), and never fails without a log.
home=$(mktemp -d); mkdir -p "$home/.claude"
echo '{"tool_input":{"command":"pkill -f x"}}' | HOME=$home python3 hooks/bash-guards.py 2>/dev/null
[ $? = 2 ] && grep -q "bash-guards	pkill" "$home/.claude/toolkit-hits.log" && ok "guard logs its blocks" || bad "guard hit log"
rm -rf "$home"

# The pre-commit framework hook points at an executable tracker.
grep -q "entry: tracker/tracker.py check" .pre-commit-hooks.yaml && [ -x tracker/tracker.py ] \
    && ok "pre-commit framework hook" || bad "pre-commit framework hook"

tests/sanitize.sh || fail=1

[ $fail = 0 ] && echo "all passed" || { echo "failures"; exit 1; }
