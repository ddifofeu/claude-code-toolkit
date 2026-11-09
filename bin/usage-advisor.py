#!/usr/bin/env python3
"""usage-advisor.py: what is left of the plan's usage, and which model and effort to give a task.

Claude Code hands the status line a JSON document on every refresh, with the plan's limits
(rate_limits.five_hour / seven_day: used_percentage, resets_at), the model and the effort. The status
line saves it (bin/statusline.sh, or a printf of its input into ~/.cache/claude-statusline.json);
this reads the latest copy.

    usage-advisor.py                      what's used and left, and when each window resets
    usage-advisor.py --risk high [--tries N] [--size S]
                                          the pick for a task: model and effort, and the commands
    usage-advisor.py --entry tracker/ST-015-*.md
                                          the same, the risk and tries read off a tracker entry

The pick minimises the expected cost of getting the task right, retries included: a cheaper level
that fails is paid for, then the next level up is paid for too. COST and FAIL below are assumptions
(relative cost of one attempt; chance an attempt fails, by the task's risk); tune them from your own
history. Model and effort can only be changed inside the session (/model, /effort): this prints them.
"""
import argparse
import glob
import json
import os
import re
import sys
import time

FEED = [os.path.expanduser("~/.cache/claude-statusline.json")]
LEVELS = ["low", "medium", "high", "xhigh", "max"]
# Relative cost of one attempt at each effort (tokens), Opus. Sonnet about 0.6 of it.
COST = {"low": 1.0, "medium": 1.6, "high": 2.6, "xhigh": 3.8, "max": 5.5}
# Chance one attempt fails, by the task's risk (low: mechanical; medium: ordinary code; high: visual,
# cross-cutting or already failed once). Each earlier failed try raises it (the easy causes are gone).
FAIL = {
    "low": {"low": 0.15, "medium": 0.08, "high": 0.05, "xhigh": 0.04, "max": 0.04},
    "medium": {"low": 0.45, "medium": 0.25, "high": 0.12, "xhigh": 0.08, "max": 0.07},
    "high": {"low": 0.8, "medium": 0.6, "high": 0.35, "xhigh": 0.2, "max": 0.15},
}
SONNET = 0.6


def feed():
    for p in FEED:
        if os.path.exists(p):
            with open(p) as f:
                return json.load(f), p
    sys.exit("no status line feed yet: add the printf to settings.json statusLine (see --help)")


def until(t):
    s = max(0, int(t - time.time()))
    return f"{s // 3600} h {s % 3600 // 60:02d} min"


def expected(level, risk, tries):
    """The expected cost of starting at `level` and stepping up a level after each failure."""
    total, reach = 0.0, 1.0
    for lv in LEVELS[LEVELS.index(level):]:
        p = min(0.95, FAIL[risk][lv] * (1 + 0.5 * tries))
        total += reach * COST[lv]
        reach *= p
    return total


def from_entry(path):
    text = open(path).read()
    tries = len(re.findall(r"\b(tried|reopened|did not hold|didn't|not fix|attempt)\b", text, re.I))
    visual = re.search(r"\b(look|visible|drawn|screenshot|notch|shape|pose|GPU)\b", text, re.I)
    kernel = re.search(r"\bkernel\b", text, re.I)
    risk = "high" if tries or (visual and kernel) else "medium" if visual or kernel else "low"
    return risk, tries


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--risk", choices=["low", "medium", "high"])
    a.add_argument("--tries", type=int, default=0, help="attempts that already failed")
    a.add_argument("--size", type=float, default=1.0, help="the task's size, in usage %% at medium effort (a guess)")
    a.add_argument("--entry", help="a tracker entry: the risk and tries read off it")
    o = a.parse_args()
    d, path = feed()
    age = time.time() - os.path.getmtime(path)
    r = d.get("rate_limits", {})
    print(f"model {d.get('model', {}).get('display_name', '?')}, effort {d.get('effort', {}).get('level', '?')} (feed {int(age // 60)} min old)")
    for name, k in (("5 hours", "five_hour"), ("7 days", "seven_day")):
        if k in r:
            print(f"  {name:8} {r[k]['used_percentage']:3d}% used, {100 - r[k]['used_percentage']:3d}% left, resets in {until(r[k]['resets_at'])}")
    if not (o.risk or o.entry):
        return
    risk, tries = (from_entry(o.entry) if o.entry else (o.risk, o.tries))
    if o.entry and o.risk:
        risk = o.risk
    plans = sorted(((expected(lv, risk, tries), lv) for lv in LEVELS), key=lambda x: x[0])
    best_cost, best = plans[0]
    left = 100 - r.get("seven_day", {}).get("used_percentage", 0)
    need = o.size * best_cost / COST["medium"]
    model = "sonnet" if risk == "low" else "opus"
    if model == "sonnet":
        need *= SONNET
    print(f"task: risk {risk}, {tries} failed tries before; expected cost by starting effort:")
    for c, lv in sorted(((c, lv) for c, lv in plans), key=lambda x: LEVELS.index(x[1])):
        print(f"  {lv:7} {c:5.2f}{'   <- pick' if lv == best else ''}")
    print(f"pick: /model {model}   /effort {best}   (about {need:.1f}% of the week, {left}% left)")
    if need > left:
        print("  not enough left this week: wait for the reset, or use API credit (/login with the Console account)")


if __name__ == "__main__":
    main()
