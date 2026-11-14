#!/usr/bin/env python3
"""Refuses a question dialog while the user is away.
Self-test: python3 ~/.claude/hooks/away-guard.py --test

A question dialog (the AskUserQuestion tool) holds the session until the user answers it. Asked
while they are asleep or out, it holds the session for hours: twice in a week a session sat about
4.5 h in one overnight, work stopped, the rest of the night's budget unused.

Two hooks, one script:
  UserPromptSubmit   python3 ~/.claude/hooks/away-guard.py prompt
                     records when the user last wrote (not a background job's notice, not a hook's
                     feedback: those arrive as prompts too, and one turned a guard like this off)
  PreToolUse         python3 ~/.claude/hooks/away-guard.py ask       (matcher: AskUserQuestion)
                     refuses the dialog when the user last wrote AWAY_GUARD_MIN minutes ago or
                     more (default 30); Claude is told to note the question where the project keeps
                     open questions and carry on. Never written yet: allowed.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

STATE = Path(os.environ.get("AWAY_GUARD_STATE", Path.home() / ".claude" / "away-guard.json"))
AWAY_MIN = float(os.environ.get("AWAY_GUARD_MIN", "30"))
# Prompts that are not the user's words: background notices and hook feedback, wrapped or not.
NOT_USER = re.compile(r"\[SYSTEM NOTIFICATION|^\s*(<[^>]+>\s*)*Stop hook feedback|<task-notification>|<agent-message", re.S)
REASON = (
    "The user last wrote {m:.0f} min ago and may be away: a question dialog would hold this session "
    "until they come back. Write the question down where this project keeps open questions (its "
    "tracker or notes), with the answer you would pick, and carry on with work that doesn't need "
    "it; ask it when the user writes again."
)


def is_user(prompt: str) -> bool:
    return bool(prompt.strip()) and not NOT_USER.search(prompt)


def away(now: float | None = None) -> float | None:
    """Minutes since the user last wrote, if AWAY_MIN or more; None if lately or never recorded."""
    try:
        t = float(json.loads(STATE.read_text())["t"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    m = ((now or time.time()) - t) / 60
    return m if m >= AWAY_MIN else None


def test() -> None:
    bad = 0
    for p in ["resume", "the hands go through the board", "Good morning"]:
        if not is_user(p):
            bad += 1; print(f"NOT THE USER'S BY MISTAKE: {p!r}")
    for p in ["<system-reminder>\n[SYSTEM NOTIFICATION - NOT USER INPUT]\n<task-notification>x</task-notification>",
              "Stop hook feedback:\nkeep going", "<system-reminder>\nStop hook feedback:\nx", "  "]:
        if is_user(p):
            bad += 1; print(f"TAKEN FOR THE USER'S: {p!r}")
    global STATE
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        STATE = Path(d) / "s.json"
        if away() is not None:
            bad += 1; print("never recorded: should allow")
        now = time.time()
        STATE.write_text(json.dumps({"t": now - 5 * 60}))
        if away(now) is not None:
            bad += 1; print("5 min ago: should allow")
        STATE.write_text(json.dumps({"t": now - 45 * 60}))
        if not away(now):
            bad += 1; print("45 min ago: should refuse")
    print(f"away-guard: 10 cases, {bad} wrong")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        event = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)
    if mode == "prompt":
        if is_user(event.get("prompt") or ""):
            try:
                STATE.parent.mkdir(parents=True, exist_ok=True)
                STATE.write_text(json.dumps({"t": time.time()}))
            except OSError:
                pass
    elif mode == "ask":
        m = away()
        if m is not None:
            # One line per block, so guards that never fire can be pruned (README, "Pruning").
            try:
                with open(Path.home() / ".claude" / "toolkit-hits.log", "a") as log:
                    log.write(f"{time.strftime('%Y-%m-%d')}\taway-guard\t{m:.0f} min\n")
            except OSError:
                pass
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                     "permissionDecisionReason": REASON.format(m=m)}}))
