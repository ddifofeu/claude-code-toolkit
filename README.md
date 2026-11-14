# claude-code-toolkit

Working rules and small guards for [Claude Code](https://claude.com/claude-code) that turn a
repeated mistake into something checked, for every project on a machine.

It is for people using Claude Code across several projects, who find that a correction made in one
session doesn't carry over to the next. The approach is to prefer enforcement over reminders: when
a mistake recurs, fix it with a test, a hook or a script that works every time, and keep the rules
file short because it costs tokens in every session.

## What is enforced, and what is only guidance

| Strength | What | Example |
|---|---|---|
| **Blocked by a hook** | [`bash-guards.py`](hooks/bash-guards.py) refuses known-bad Bash commands and names the safe alternative | `pkill -f worker` can match the shell running it. Also refuses git commands that skip hooks |
| **Blocked by a hook, when configured** | [`heavy-guard.py`](hooks/heavy-guard.py) refuses a heavy step (a release build, a full test suite) while this machine is busy and a peer is idle, naming the line that runs it there | `cargo test --release` at load 20 on 32 cores while a build machine idles. Off until `~/.claude/heavy-guard.json` exists |
| **Sent back once by a hook** | [`promise-guard.py`](hooks/promise-guard.py) returns a turn that ends on a promise with nothing started | "I'll start it now" with no tool call |
| **Blocked by a hook** | [`away-guard.py`](hooks/away-guard.py) refuses a question dialog once the user's last message is 30 minutes old (`AWAY_GUARD_MIN`): the question is noted and asked when they write again | A dialog asked at 03:30 that held the session until 08:00 |
| **Checked at commit** | The [tracker](tracker/tracker.py) check, and the [sanitisation scan](tests/sanitize.sh) for repositories that use it | A fixed bug whose regression test was deleted |
| **Run on demand** | [`budget-scan.py`](bin/budget-scan.py), [`supervise.sh`](bin/supervise.sh), [`usage-advisor.py`](bin/usage-advisor.py), [`statusline.sh`](bin/statusline.sh) | Tests that assert a wall-clock time budget |
| **Guidance only** | [`CLAUDE.md`](CLAUDE.md), which Claude Code reads but nothing forces it to follow | "Match the effort to the problem" |

Guards cover the patterns they list, and only commands that go through the Bash tool. They reduce
known mistakes but can't prevent mistakes in general.

## Status

A small personal toolkit, started in November 2026 and still changing.

- **Tests:** `tests/run.sh` passed on 2026-11-14 on Linux (39 checks), including all bash-guard and
  heavy-guard cases and the away guard's. macOS is intended but has no recorded test run.
- **Effect:** guards log their blocks locally for pruning. The repository publishes no figures on
  how often they fire or how many mistakes they prevent.

## Install

Read [`install.sh`](install.sh) and [`sync.sh`](sync.sh) first. They change your Claude Code
configuration, and the hooks run in every session.

```bash
curl -fsSL https://raw.githubusercontent.com/ddifofeu/claude-code-toolkit/main/install.sh | bash
```

Or clone and run `./install.sh`. To keep your own version in sync, fork it and run
`TOOLKIT_REPO=you/your-fork ./install.sh`. Needs `bash`, `python3` and `curl`.

**Updates are automatic and unpinned.** At the start of each session, a hook fetches the toolkit's
files from the `main` branch of the source repository and replaces the installed copies, including
`CLAUDE.md` and the hook scripts. Local edits to those files are overwritten without a backup, and
updates aren't reviewed first. Install from a fork you control if you want to decide when changes
arrive.

## Claude Code on the web

Cloud sessions don't read your machine's `~/.claude`. Two steps, once:

1. **Rules and tools in every web session.** At claude.ai/code, open the environment you use (the
   environment selector, then its settings), keep network access at *Trusted* (it allows GitHub),
   and set its **setup script** to:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ddifofeu/claude-code-toolkit/main/install.sh | bash
   ```

   It runs before each new session's environment is built, so `CLAUDE.md`, `procs.sh`, the guard
   and the tracker are in place. Cached environments are rebuilt within about a week, which is
   when toolkit updates reach them. Check in a session with `/context`: `~/.claude/CLAUDE.md` is
   listed under memory files.
2. **The command guard, per repository you use on the web.** Cloud sessions read a repository's
   `.claude/settings.json` (single-repository sessions), not your user settings, so copy
   `cloud/repo-settings.json` there (or merge its hook into the existing file). The hook runs only
   in web sessions (`CLAUDE_CODE_REMOTE=true`), so locally the guard doesn't run twice.

Multi-repository sessions and Claude Projects threads don't read repository hooks; they still get
the rules from step 1.

## What it installs (in `~/.claude`)

| File | Does |
|---|---|
| `CLAUDE.md` | The working rules Claude Code reads in every session (an existing file is kept as `CLAUDE.md.bak-*`) |
| `bin/procs.sh` | Find or stop processes by command line without ever matching the caller |
| `hooks/bash-guards.py` | Refuses commands that are known to go wrong, naming the safe alternative: pkill/pgrep/killall (they match their own caller), and git skipping its hooks (`--no-verify`, `-c core.hooksPath=`) |
| `hooks/heavy-guard.py` | Refuses a heavy step while this machine is busy and a peer you name is idle, with the command that runs it there; allows everything until you write `~/.claude/heavy-guard.json` (see [heavy-guard.py](#heavy-guardpy)) |
| `hooks/promise-guard.py` | Sends a turn back once when it ends on "I'll start it now" with nothing started: a turn only restarts on your message or a background job's notification (not when the message asks you for what the work needs, or the turn set a timer or a background job) |
| `bin/supervise.sh` | Runs a job so nothing of it outlives it: its own process group, an optional deadline (exit 124), and on any ending kills the group and every process still marked in its environment (a detached headless browser included); `--exit FILE` is written only once nothing is left |
| `bin/budget-scan.py` | Flags tests that assert a time budget on the wall clock: runners that run files side by side make them fail at random; measure the test's CPU time instead (`process.cpuUsage()`, `time.process_time()`) |
| `bin/statusline.sh` | A status line that keeps Claude Code's own feed (`~/.cache/claude-statusline.json`) and shows the plan's 5-hour and weekly usage, the model and the effort: `"statusLine": {"type": "command", "command": "~/.claude/bin/statusline.sh"}` |
| `bin/usage-advisor.py` | What's left of the plan and when it resets, and which `/model` and `/effort` to give a task (`--risk low|medium|high`, `--tries N`, or `--entry` a tracker entry): the expected cost of getting it right, a failed cheaper try and its retry one level up included. `--apply` makes the pick the default for new sessions and prints `claude --resume <session> --model M --effort E` to carry on this conversation with it (a running session changes them only with `/model` and `/effort`) |
| `tracker/tracker.py`, `tracker/pre-commit` | A bug and change tracker to copy into a project, with its commit check |
| `hooks/sync-toolkit.sh` | Refreshes these files from GitHub at the start of each session |

It also adds four hooks to `~/.claude/settings.json`, keeping everything already there (a backup is
written first): `SessionStart` runs the sync, `PreToolUse` on Bash runs the guard and the heavy-step
guard, `Stop` runs the promise guard. Running the installer again doesn't duplicate the hooks (and
adds one a newer toolkit brought); it only adds another dated settings backup. To remove: delete the
four hooks (or use `/hooks`) and the files.

## The rules (`CLAUDE.md`)

0. **Proportion**: effort matched to the problem; enforce with code (tests, hooks, scripts) before
   prose, since the rules file is read in every session.
1. **A glitch seen twice gets a persistent, validated fix**: a script, a guard in the code, or a
   hook that blocks the bad pattern, proven by a test, not another manual workaround.
2. **Bugs and requested changes are tracked until verified, and don't come back**: a status and
   its blockers, a regression test per fix, tests run before every commit and never loosened, a
   broken fix reopened rather than refiled, contradictions with earlier decisions raised.
3. **General lessons come back here**: a fix that helps beyond one project is added to this repo
   with a test, sanitised, and rules that never fire are removed.

## Contributing a lesson

A tool or guard, a case in its tests, `tests/run.sh` passing, a README line. Add a line to
`CLAUDE.md` only when code can't enforce it: that file costs tokens in every session.
Contributors run `git config core.hooksPath .githooks` once: every commit then runs `tests/run.sh`,
including `tests/sanitize.sh` (no emails, IPs, home paths, keys or tokens; commit authors must be
GitHub noreply addresses). Put your own private words, one per line, in
`~/.claude/toolkit-private-words` (never committed) and the scan refuses them too.

## Pruning

Each guard block adds a line to `~/.claude/toolkit-hits.log` (date, guard, command). Now and then,
look at it on each machine: a guard or rule that hasn't fired in months is a candidate for removal,
so the toolkit stays small. Rules in `CLAUDE.md` have no log; review them at the same time.

## Using existing tools

Projects on GitHub can track in GitHub issues instead of `tracker/`; the rules apply the same way.
Projects that use the [pre-commit framework](https://pre-commit.com) get the tracker check with:

```yaml
- repo: https://github.com/ddifofeu/claude-code-toolkit
  rev: main
  hooks: [{id: tracker-check}]
```

The install and sync scripts do what a Claude Code plugin marketplace does. While the toolkit is a
few files they are simpler; once it holds several hooks, skills or commands, packaging it as a
plugin (installed with `/plugin`) is the better route.

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
`killall` in command position (also after `if`, `while`, `until`, `!`, `(` or `{`, as in a
wait loop), pointing to `procs.sh`. Quoted text and heredocs are ignored
(commit messages, grep patterns, files written with `cat`), except what will run: `ssh HOST '...'`,
`bash -c '...'`, heredocs fed to a shell. Add your own refusals to `EXTRA_RULES`, and a case to
`bash-guards.cases.json` for each; `python3 hooks/bash-guards.py --test` checks them all.

## heavy-guard.py

A `PreToolUse` hook for Bash, for people with a second machine. An agent runs the release build or
the whole test suite on the machine it sits on, even when that one is loaded and another is idle.
The guard refuses such a step (exit 2) only when all hold: the command runs a heavy step here (a
pattern from the config, in command position; quoted text, text heredocs and `ssh HOST '...'`
don't count); this machine, with the step's threads added, is over `busy` per core
((load1 + threads) / cores); and a peer is under `idle` per core. The message names the line that
runs it on that peer, and `HEAVY_LOCAL=1 <command>` to run it here anyway.

Allowed: no config (the default: the hook does nothing), `HEAVY_LOCAL=1` in the command or the
environment, a command that matches `runner` (already going elsewhere) or runs inside `ssh`, light
commands, no peer answering. A leading `cd DIR &&` is where the step runs (`{dir}`). Peers are
probed only when this machine is busy, all at once, 1.5 s at most in total; their loads (or their
silence) are cached for 60 s in `~/.claude/heavy-guard-load.json`. Each block is logged like the
other guards'. Hooks fire only for Claude's Bash tool calls, so a git hook's test run isn't guarded.

`~/.claude/heavy-guard.json` (the example from
[`heavy-guard.cases.json`](hooks/heavy-guard.cases.json); `python3 hooks/heavy-guard.py --test`
checks its patterns against the cases there):

```json
{
  "heavy": [
    {"name": "cargo-release", "threads": 16, "pattern": "cargo\\s+(?:\\+\\S+\\s+)?(?:test|build|bench)\\b[^;&|\\n]*\\s--release\\b"},
    {"name": "make-parallel", "threads": 8, "pattern": "make\\b[^;&|\\n]*\\s-j"},
    {"name": "npm-test", "threads": 8, "pattern": "npm\\s+(?:run\\s+)?test(?![:\\w-])"},
    {"name": "pytest", "threads": 8, "pattern": "(?:python3?\\s+-m\\s+)?pytest\\b"}
  ],
  "peers": ["build-box"],
  "run_elsewhere": "ssh {host} 'cd {dir} && {command}'",
  "runner": "\\bmy-runner\\b",
  "busy": 0.6,
  "idle": 0.25
}
```

- `heavy`: a regular expression for each heavy step (matched where a command starts) and the threads
  it takes.
- `peers`: hosts probed with `ssh -o BatchMode=yes HOST` reading `/proc/loadavg` and `nproc` (Linux).
  Or `probe`: a command that prints `HOST LOAD CORES` lines (another OS, or a scheduler of your own).
- `run_elsewhere`: the line the message names. `{host}`, `{dir}`, `{threads}`, and `{command}` as
  written, so the example assumes it has no single quotes; `{remote}` is `cd DIR && COMMAND` quoted
  as one shell word (the default is `ssh {host} {remote}`). The peer needs the same directory, or
  name your own runner here.
- `runner`: a regular expression for commands that already run elsewhere (your runner).
- `busy`, `idle`: per-core thresholds, 0.6 and 0.25 by default. Busy counts the step's own threads:
  at load 10 on 32 cores a machine is at 0.31 before a 16-thread build, 0.81 with it.

## The tracker

Copy `tracker/tracker.py` to `tools/tracker.py` and `tracker/pre-commit` to `.githooks/pre-commit`
in a project, then `git config core.hooksPath .githooks`.

```bash
python3 tools/tracker.py new bug "Login fails after timeout" owner   # numbered past every branch and worktree
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

`tests/run.sh` checks the guard cases and its hit log, `procs.sh` against itself, the tracker's
rejections, the pre-commit framework hook, the web-session repo hook, the promise guard, `budget-scan`,
the heavy-step guard (with a fake `ssh` and load, no other machine) and the sanitisation scan.

Tests that run from a git pre-commit hook inherit `GIT_DIR` and `GIT_INDEX_FILE`, so their own git
calls, even `git -C other-dir`, act on the repository being committed: a test's `git init/add/commit`
in a temporary folder wrote its files into the caller's index and commits onto its branch. Clear
those variables at the top of such tests and in the tools they spawn; `tests/run.sh` does.

## How this was built

Every rule so far came from a failure I saw in my own Claude Code sessions. Development is
AI-assisted: most commits carry a Claude co-author trailer. The tools are plain `bash` and `python3`,
and they build on Claude Code's hooks and settings.

## Licence

MIT, see `LICENSE`.
