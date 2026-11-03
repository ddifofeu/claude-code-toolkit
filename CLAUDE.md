# Working rules (every project, every session)

<!-- From github.com/ddifofeu/claude-code-toolkit (CLAUDE.md), installed in ~/.claude/CLAUDE.md
     and refreshed at session start. Loaded in every session: keep it short; details go in docs. -->

## 0. Proportion
Every fix, rule and process costs time and tokens. Match the effort to the problem and its odds of
coming back, and prefer the cheapest thing that reliably works. Enforce with code (a test, then a
hook or guard, then a script) rather than prose: code works every time at no token cost.
Don't add process to a one-off.

## 1. A glitch seen twice gets a persistent, validated fix
The second time something goes wrong the same way, stop working around it: fix the root cause with
a script, a guard in the code, or a hook that blocks the bad pattern, and prove it with a test or
a live trigger, including that it doesn't block legitimate use. Note it where the project lists
its tools.

Installed with these rules: `~/.claude/bin/procs.sh list|count|kill [-SIG] PATTERN|alive PID...`
to find or stop processes (never pkill/pgrep/killall: they match the calling shell; a hook refuses
them; on another machine `ssh HOST bash -s -- kill PATTERN < ~/.claude/bin/procs.sh`).

## 2. Bugs and requested changes are tracked until verified, and don't come back
For projects with ongoing work (a one-off script needs only its test):
- **Track at once** in the project's tracker (GitHub issues if it uses them, else `tracker/` with
  `~/.claude/tracker/tracker.py`): status open → in-progress → fixed → verified, or blocked (what,
  who must act) or wontfix (the owner's reason). Answer "where are we" from it.
- **No fix without a regression test** that fails without the fix; the entry names it. Verified
  means the owner or a real end-to-end run confirmed it.
- **Nothing slips back:** run the regression tests before every commit (pre-commit hook). Never
  delete or loosen a test to make a change pass; if old behaviour must change, ask the owner. A
  fix that breaks again is reopened, put first, and reported plainly.
- **Forward, not back and forth:** read an entry before changing what it covers; if a request
  contradicts an earlier decision, say so and let the owner choose.

## 3. Lessons that apply beyond one project go to the toolkit
When a fix from rule 1 or 2 would help other projects (not project-specific), propose adding it to
github.com/ddifofeu/claude-code-toolkit, in one line, and do it on the owner's OK: the tool or guard
plus a case in its tests (`tests/run.sh` must pass), a line in the README, and a line here only if
code can't enforce it. The repo is public: no secrets, hostnames, IPs, emails or private project
names; commit with the owner's GitHub noreply address. Remove rules and guards that never fire.
