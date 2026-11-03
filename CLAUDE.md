# Working rules (every project, every session)

<!-- From github.com/ddifofeu/claude-code-toolkit (CLAUDE.md). install.sh puts it in
     ~/.claude/CLAUDE.md, and a session-start hook refreshes it; to change it, edit your fork. -->

## 1. A glitch seen twice gets a persistent, validated fix
The second time something goes wrong the same way (a tool misbehaving, a step that keeps failing,
a manual workaround repeated), stop working around it. Fix the root cause with something that
persists: a committed script or helper, a guard in the code, or a hook that blocks the bad pattern.
Validate it before calling it done: a test, self-test cases, or a live trigger, including a check
that it doesn't block legitimate use. Record it where the project lists its tools (README or a
tools doc) so later sessions use it.

Fixes installed with these rules:
- **Finding or stopping processes:** `~/.claude/bin/procs.sh list|count|kill [-SIG] PATTERN`,
  `alive PID...` (on another box: `ssh HOST bash -s -- kill PATTERN < ~/.claude/bin/procs.sh`).
  Never pkill/pgrep/killall: their pattern matches the calling shell too, so they kill or count
  their own caller (a hook refuses them). Better still, keep the PIDs of what you start (`$!`).

## 2. Every bug and every requested change is tracked until it is verified, and never comes back
Applies to bugs the owner reports, bugs I detect, and changes the owner requests, in any app or game.

**Track it at once.** Before working on it, add an entry to the project's tracker (see *Tracker*
below) with an ID, a one-line title, the kind (bug, change), who reported it and when, and its status:

    open → in-progress → fixed → verified          (or blocked: <what, who> · wontfix: <owner's reason>)

Update the entry as work moves: the commit that fixed it, and what is blocking it and who must act.
When the owner asks "where are we", answer from the tracker, not from memory.

**No fix without a regression test.** A bug is not fixed until a test exists that fails without the
fix and passes with it (run it both ways when practical). A change is not done until a test pins the
new behaviour. The entry names the test. "Verified" means the owner (or a real-device or end-to-end
run) confirmed it, not only that the test passes.

**Nothing slips back.** Before every commit, run the regression tests and the tracker check. Never
delete, skip or loosen a regression test to make a change pass. If the new work truly needs the
old behaviour to change, stop and ask the owner; record the decision in both entries.
A fixed entry that breaks again is reopened, not filed anew; its history keeps the regression,
it goes to the top of the list, and the report to the owner says so plainly.

**Forward, not back and forth.** Before changing behaviour that an entry covers, read that entry:
its earlier decisions and fix. If a request contradicts an earlier fix or decision, point it out
and let the owner choose, instead of flipping between the two.

**Tracker.** If the project has none, create the lightest one that can be checked by a script: one
file per entry in a `tracker/` folder (fields: id, title, kind, status, reported, blocker,
regression test, fixed in, history), a small `check` command that fails when a fixed or verified
entry names no regression test or names one that doesn't exist, and run that check before commits
(git pre-commit hook). `~/.claude/tracker/tracker.py` and `~/.claude/tracker/pre-commit` do this:
copy them into the project (`tools/tracker.py`, `.githooks/pre-commit`). Reuse the project's own tracker if it has one (GitHub issues, a TODO file),
adding what's missing rather than starting a second one.
