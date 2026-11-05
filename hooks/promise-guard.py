#!/usr/bin/env python3
"""Stop hook: refuses to end a turn whose last message promises work that nothing will start.
Self-test: python3 ~/.claude/hooks/promise-guard.py --test

A turn ends when Claude answers without a tool call, and only the user's next message or a
background job's notification starts another. "I'll start the training round now" as the last
words of a turn left the machines idle all night; that and four more like it, in one week.
Flagged: an unconditional "I'll / I will / next I'll / I'm starting ..." sentence, and "after
08:00, I'll ...", which no notification triggers. Not flagged: work waiting on the user ("tell
me", "if you", "when you") or on a running job ("when it finishes", "once mining ends"); any
promise in a message that asks the user for what the work needs ("send me the port"); and any
promise in a turn that set a timer or started a background job (ScheduleWakeup, CronCreate,
run_in_background), which will bring Claude back. Those two were blocked by mistake five times in a
night.
Claude is sent back once (stop_hook_active then lets it stop): do the work now, start a
background job or a timer that will come back, or say plainly that it is not started.
"""
import json
import re
import sys
import time
from pathlib import Path

COMMIT = re.compile(r"\b(I'll|I will|I'm going to|I'm (?:now )?starting|I am starting)\b", re.I)
# Waiting on the user or on something that will notify: the sentence is a condition, not a promise.
WAITS = re.compile(
    r"\b(you|your|tell me|if|unless|or skip|when (?:it|they|that|this|the \w+|both|each|mining|training) "
    r"(?:\w+ )?(?:finish|end|is done|are done|complete|come)|once (?:it|they|that|this|the \w+|both|mining|training) "
    r"(?:\w+ )?(?:finish|end|is done|are done|complete|come|show)|when (?:it|they)'s done|I'll report|I'll tell)",
    re.I,
)
# The message asks the user for something the work waits on: the next user message restarts it.
NEEDS_USER = re.compile(r"\b(send me|tell me|give me|I need (?:your|you to)|once you|when you|after you)\b", re.I)
# Tool calls that bring Claude back without the user.
COMEBACK = {"ScheduleWakeup", "CronCreate"}
REASON = (
    "Your last message promises work this turn has not started: {s!r}. Nothing will run it: a turn "
    "only restarts on the user's message or a background job's notification. Do the work now with "
    "a tool call, or start the background job or timer that will bring you back, or say plainly "
    "that it is not started and what will start it."
)


# Quoted words are cited, not promised (the first live run flagged a quote of an old promise).
QUOTED = re.compile(r'"[^"\n]*"|\u201c[^\u201d\n]*\u201d|`[^`\n]*`')


def broken_promise(text: str) -> str | None:
    if NEEDS_USER.search(QUOTED.sub("", text)):
        return None
    for s in re.split(r"(?<=[.!?:])\s+|\n+", text):
        if COMMIT.search(QUOTED.sub("", s)) and not WAITS.search(s):
            return s.strip()
    return None


def comes_back(entries: list[dict]) -> bool:
    """True when this turn (since the user's last typed message) set a timer or a background job."""
    back = False
    for d in entries:
        content = (d.get("message") or {}).get("content")
        if d.get("type") == "user" and isinstance(content, str):
            back = False
        elif d.get("type") == "assistant" and isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use" and (
                        c.get("name") in COMEBACK or (c.get("input") or {}).get("run_in_background")):
                    back = True
    return back


def transcript(event: dict) -> list[dict]:
    try:
        with open(event["transcript_path"]) as f:
            return [json.loads(line) for line in f if line.strip()]
    except (KeyError, OSError, ValueError):
        return []


def last_text(event: dict) -> str:
    if event.get("last_assistant_message"):
        return event["last_assistant_message"]
    text = ""
    try:
        with open(event["transcript_path"]) as f:
            for line in f:
                d = json.loads(line)
                if d.get("type") == "assistant":
                    parts = [c.get("text", "") for c in d["message"].get("content", [])
                             if isinstance(c, dict) and c.get("type") == "text"]
                    if parts:
                        text = "\n".join(parts)
                elif d.get("type") == "user" and isinstance(d["message"].get("content"), str):
                    text = ""  # a new user message: only this turn's answer counts
    except (KeyError, OSError, ValueError):
        pass
    return text


def test() -> None:
    cases = json.load(open(__file__.replace(".py", ".cases.json")))
    bad = 0
    for text in cases["flag"]:
        if not broken_promise(text):
            bad += 1; print(f"NOT FLAGGED: {text}")
    for text in cases["pass"]:
        if (s := broken_promise(text)):
            bad += 1; print(f"FLAGGED BY MISTAKE: {s}")
    def turn(*tools):
        return [{"type": "user", "message": {"content": "go"}}] + [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": n, "input": i}]}}
            for n, i in tools]
    turns = ((turn(("ScheduleWakeup", {"delaySeconds": 600})), True),
             (turn(("Bash", {"command": "make", "run_in_background": True})), True),
             (turn(("Bash", {"command": "git push"})), False),
             (turn(("ScheduleWakeup", {})) + [{"type": "user", "message": {"content": "next"}}], False))
    for entries, want in turns:
        if comes_back(entries) != want:
            bad += 1; print(f"comes_back should be {want}: {entries[1:]}")
    print(f"promise-guard: {len(cases['flag']) + len(cases['pass']) + len(turns)} cases, {bad} wrong")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
    event = json.load(sys.stdin)
    if event.get("stop_hook_active"):
        sys.exit(0)
    s = broken_promise(last_text(event))
    if s and not comes_back(transcript(event)):
        # One line per block, so guards that never fire can be pruned (README, "Pruning").
        try:
            with open(Path.home() / ".claude" / "toolkit-hits.log", "a") as log:
                log.write(f"{time.strftime('%Y-%m-%d')}\tpromise-guard\t{s[:60]}\n")
        except OSError:
            pass
        print(json.dumps({"decision": "block", "reason": REASON.format(s=s)}))
