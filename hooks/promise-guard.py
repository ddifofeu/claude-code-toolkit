#!/usr/bin/env python3
"""Stop hook: refuses to end a turn whose last message promises work that nothing will start.
Self-test: python3 ~/.claude/hooks/promise-guard.py --test

A turn ends when Claude answers without a tool call, and only the user's next message or a
background job's notification starts another. "I'll start the training round now" as the last
words of a turn left the machines idle all night; that and four more like it, in one week.
Flagged: an unconditional "I'll / I will / next I'll / I'm starting ..." sentence, and "after
08:00, I'll ...", which no notification triggers. Not flagged: work waiting on the user ("tell
me", "if you", "when you") or on a running job ("when it finishes", "once mining ends").
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
REASON = (
    "Your last message promises work this turn has not started: {s!r}. Nothing will run it: a turn "
    "only restarts on the user's message or a background job's notification. Do the work now with "
    "a tool call, or start the background job or timer that will bring you back, or say plainly "
    "that it is not started and what will start it."
)


# Quoted words are cited, not promised (the first live run flagged a quote of an old promise).
QUOTED = re.compile(r'"[^"\n]*"|\u201c[^\u201d\n]*\u201d|`[^`\n]*`')


def broken_promise(text: str) -> str | None:
    for s in re.split(r"(?<=[.!?:])\s+|\n+", text):
        if COMMIT.search(QUOTED.sub("", s)) and not WAITS.search(s):
            return s.strip()
    return None


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
    print(f"promise-guard: {len(cases['flag']) + len(cases['pass'])} cases, {bad} wrong")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
    event = json.load(sys.stdin)
    if event.get("stop_hook_active"):
        sys.exit(0)
    s = broken_promise(last_text(event))
    if s:
        # One line per block, so guards that never fire can be pruned (README, "Pruning").
        try:
            with open(Path.home() / ".claude" / "toolkit-hits.log", "a") as log:
                log.write(f"{time.strftime('%Y-%m-%d')}\tpromise-guard\t{s[:60]}\n")
        except OSError:
            pass
        print(json.dumps({"decision": "block", "reason": REASON.format(s=s)}))
