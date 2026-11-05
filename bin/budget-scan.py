#!/usr/bin/env python3
"""budget-scan.py: flags tests that assert on wall-clock time.

Test runners that run files side by side (node --test, pytest -n, go test -p) load the machine, so
a budget measured on the wall clock fails at random although the code did the same work. Measure
the test's own CPU time instead:

    JavaScript   process.cpuUsage()  ->  (user + system) / 1000 ms
    Python       time.process_time()
    Go           syscall.Getrusage(RUSAGE_SELF) (or a benchmark)

    budget-scan.py [PATH ...]   scan test files (default: the current directory); exit 1 on a hit

A hit is an assertion line that uses a wall-clock reading, directly or through a name assigned
from one in the same file. Mark a line that really means the wall clock with `wall-clock-ok`.
"""
import re
import sys
from pathlib import Path

WALL = re.compile(r"performance\.now\(\)|Date\.now\(\)|new Date\(\)\.getTime\(\)|time\.time\(\)|time\.perf_counter\(\)|time\.monotonic\(\)|time\.Now\(\)|time\.Since\(")
ASSIGN = re.compile(r"(?:const|let|var)?\s*([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*[^=].*")
ASSERT = re.compile(r"\bassert\w*\b|\bexpect\(|\bt\.(?:Error|Fatal)f?\(|\bself\.assert")
TEST_FILE = re.compile(r"(^test_.*\.py$|.*_test\.(py|go)$|.*\.(test|spec)\.(m?js|cjs|ts|tsx)$)")


def scan(path: Path):
    lines = path.read_text(errors="replace").splitlines()
    names = set()
    for line in lines:
        if WALL.search(line):
            m = ASSIGN.search(line)
            if m:
                names.add(m.group(1))
    # A name derived from a wall-clock name (elapsed = performance.now() - t0) counts too.
    for _ in range(3):
        for line in lines:
            m = ASSIGN.search(line)
            if m and any(re.search(rf"\b{re.escape(n)}\b", line.split("=", 1)[1]) for n in names):
                names.add(m.group(1))
    for i, line in enumerate(lines, 1):
        if "wall-clock-ok" in line or not ASSERT.search(line):
            continue
        if WALL.search(line) or any(re.search(rf"\b{re.escape(n)}\b", line) for n in names):
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
