#!/usr/bin/env python3
"""budget-scan.py: flags tests that assert on wall-clock time.

Test runners that run files side by side (node --test, pytest -n, go test -p) load the machine, so
a budget measured on the wall clock fails at random although the code did the same work. Measure
the test's own CPU time instead:

    JavaScript   process.cpuUsage()  ->  (user + system) / 1000 ms
    Python       time.process_time()
    Go           syscall.Getrusage(RUSAGE_SELF) (or a benchmark)

    budget-scan.py [PATH ...]   scan test files (default: the current directory); exit 1 on a hit

A hit is an assertion that bounds (<, >, Less, Greater) a wall-clock duration: a difference of
clock readings, directly or through a name assigned from one in the same file. Mark a line that
really means the wall clock with `wall-clock-ok`.
"""
import re
import sys
from pathlib import Path

WALL = re.compile(r"performance\.now\(\)|Date\.now\(\)|new Date\(\)\.getTime\(\)|time\.time\(\)|time\.perf_counter\(\)|time\.monotonic\(\)|time\.Now\(\)|time\.Since\(")
ASSIGN = re.compile(r"(?:(?:const|let|var)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*[^=]")
BOUND = re.compile(r"<|>|\bLess|\bGreater|toBeLessThan|toBeGreaterThan|assertLess|assertGreater")
ASSERT = re.compile(r"\bassert\w*\b|\bexpect\(|\bt\.(?:Error|Fatal)f?\(|\bself\.assert")
TEST_FILE = re.compile(r"(^test_.*\.py$|.*_test\.(py|go)$|.*\.(test|spec)\.(m?js|cjs|ts|tsx)$)")


def scan(path: Path):
    lines = path.read_text(errors="replace").splitlines()
    # Names read straight from a clock (t0 = performance.now()), then differences of them
    # (elapsed = performance.now() - t0): only those carry a duration.
    clock = set()
    for line in lines:
        m = ASSIGN.match(line.strip())
        if m and WALL.search(line.split("=", 1)[1]):
            clock.add(m.group(1))
    used = lambda text: WALL.search(text) or any(re.search(rf"\b{re.escape(n)}\b", text) for n in clock)
    durations = set()
    for line in lines:
        m = ASSIGN.match(line.strip())
        if m and "-" in line.split("=", 1)[1] and used(line.split("=", 1)[1]):
            durations.add(m.group(1))
    for i, line in enumerate(lines, 1):
        if "wall-clock-ok" in line or not ASSERT.search(line) or not BOUND.search(line):
            continue
        if (WALL.search(line) and "-" in line) or any(re.search(rf"\b{re.escape(n)}\b", line) for n in durations) \
                or (any(re.search(rf"\b{re.escape(n)}\b", line) for n in clock) and WALL.search(line)):
            yield i, line.strip()


def main(argv):
    roots = [Path(a) for a in argv] or [Path(".")]
    files = []
    for r in roots:
        if r.is_file():
            files.append(r)
        else:
            files += [p for p in r.rglob("*") if p.is_file() and TEST_FILE.match(p.name) and "node_modules" not in p.parts]
    hits = 0
    for f in sorted(files):
        for line_no, text in scan(f):
            hits += 1
            print(f"{f}:{line_no}: a time budget on the wall clock: {text}")
    if hits:
        print("Measure CPU time instead (process.cpuUsage(), time.process_time()); mark a real wall-clock check with wall-clock-ok.")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
