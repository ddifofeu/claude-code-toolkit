# claude-code-toolkit

Working rules and small tools that stop [Claude Code](https://claude.com/claude-code) sessions
from repeating the same mistakes, for every project on a machine.

```bash
curl -fsSL https://raw.githubusercontent.com/ddifofeu/claude-code-toolkit/main/install.sh | bash
```

Or clone and run `./install.sh`. To keep your own version in sync, fork it and run
`TOOLKIT_REPO=you/your-fork ./install.sh`. Needs `bash`, `python3` and `curl` (Linux or macOS).

## What it installs (in `~/.claude`)

| File | Does |
|---|---|
| `CLAUDE.md` | The working rules Claude Code reads in every session (an existing file is kept as `CLAUDE.md.bak-*`) |
| `bin/procs.sh` | Find or stop processes by command line without ever matching the caller |
| `hooks/bash-guards.py` | Refuses commands that are known to go wrong, naming the safe alternative |
| `tracker/tracker.py`, `tracker/pre-commit` | A bug and change tracker to copy into a project, with its commit check |
| `hooks/sync-toolkit.sh` | Refreshes these files from GitHub at the start of each session |

It also adds two hooks to `~/.claude/settings.json`, keeping everything already there (a backup is
written first): `SessionStart` runs the sync, `PreToolUse` on Bash runs the guard. Running the
installer again changes nothing. To remove: delete the two hooks (or use `/hooks`) and the files.

## The rules (`CLAUDE.md`)

1. **A glitch seen twice gets a persistent, validated fix**: a script, a guard in the code, or a
   hook that blocks the bad pattern, proven by a test, not another manual workaround.
2. **Every bug and requested change is tracked until verified, and never comes back**: tracked at
   once with a status and its blockers, fixed only with a regression test named in the entry,
   tests run before every commit and never loosened to make a change pass, a broken fix reopened
   rather than refiled, and contradictions with earlier decisions raised instead of flip-flopping.

## procs.sh

```bash
procs.sh list  PATTERN          # PID and command line of matching processes
procs.sh count PATTERN          # how many (exit 1 when none)
procs.sh kill [-SIG] PATTERN    # signal them (default TERM)
procs.sh alive PID...           # exit 0 when every PID is running
ssh HOST bash -s -- kill PATTERN < ~/.claude/bin/procs.sh   # on another machine
```

`pgrep -f` and `pkill -f` match every full command line, including the shell running them:
`bash -c "... pkill -f worker"` contains `worker`, so the command kills (or counts) itself, and
over ssh it kills the remote shell. `procs.sh` skips its caller and every parent, shells, ssh and
itself, so it only finds the actual programs.

## bash-guards.py

A `PreToolUse` hook for Claude Code's Bash tool. Built in: it refuses `pkill`, `pgrep` and
`killall` in command position, pointing to `procs.sh`. Quoted text and heredocs are ignored
(commit messages, grep patterns, files written with `cat`), except what will run: `ssh HOST '...'`,
`bash -c '...'`, heredocs fed to a shell. Add your own refusals to `EXTRA_RULES`, and a case to
`bash-guards.cases.json` for each; `python3 hooks/bash-guards.py --test` checks them all.

## The tracker

Copy `tracker/tracker.py` to `tools/tracker.py` and `tracker/pre-commit` to `.githooks/pre-commit`
in a project, then `git config core.hooksPath .githooks`.

```bash
python3 tools/tracker.py new bug "Login fails after timeout" owner
python3 tools/tracker.py list            # open work; reopened entries first
python3 tools/tracker.py check           # run by the pre-commit hook
```

One Markdown file per entry in `tracker/`:

```
# T-007 Login fails after timeout
kind: bug
status: fixed            # open | in-progress | blocked | fixed | verified | wontfix
reported: 2026-01-12, owner
blocker: -               # required when blocked: what blocks it, and who must act
test: tests/test_login.py::test_login_after_timeout
fixed-in: 3f2a9c1

## History
- 2026-01-12 open: reported by owner
- 2026-01-13 fixed (3f2a9c1): session refresh before retry
```

`check` fails when a fixed or verified entry names no regression test, names a file that doesn't
exist, or names a test the file no longer contains, so a deleted test can't slip through.

## Tests

`tests/run.sh` checks the guard cases, `procs.sh` against itself, and the tracker's rejections.

## Licence

MIT, see `LICENSE`.
