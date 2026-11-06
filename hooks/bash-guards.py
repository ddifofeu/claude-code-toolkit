#!/usr/bin/env python3
"""Claude Code PreToolUse hook for Bash: refuses commands known to go wrong, naming the safe
alternative. Self-test: python3 bash-guards.py --test

Built in: skipping git hooks (`--no-verify`, `-c core.hooksPath=...`): the pre-commit hook is
where the regression tests run; a commit that skips it can put a breaking change on a branch.

Also built in: pkill / pgrep / killall. Their pattern is matched against every full command line,
including the shell that runs them (`bash -c "... pkill -f PATTERN"` contains PATTERN), so they
kill or count their own caller, and over ssh the remote shell. Use procs.sh instead.

Text inside quotes and heredocs is ignored (commit messages, grep patterns, files written with
cat), except what will run: ssh HOST '...', bash -c '...', and heredocs fed to bash/sh/ssh.

Add your own refusals to EXTRA_RULES: (regex over the command, message).
"""
import json
import re
import sys
from pathlib import Path

QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
# The tool in command position: start, after a separator, $( / backtick, a subshell or group
# ( { or a negation !, or after xargs/sudo/exec/nohup/env/time, a shell keyword
# (if/elif/then/else/while/until/do) or timeout N.
PROCESS_TOOL = re.compile(
    r"(?:^|[;&|`\n({!]|\$\(|\b(?:xargs|sudo|exec|nohup|env|time|if|elif|then|else|while|until|do)\s|\btimeout\s+\S+\s)\s*(pkill|pgrep|killall)\b"
)
# git told to skip its hooks: --no-verify (commit, push, merge, am) or an inline core.hooksPath.
HOOK_SKIP = re.compile(r"\bgit\b[^;&|\n]*?(?:\s--no-verify\b|\s-c\s*core\.hooks[Pp]ath\s*=)")
HOOK_HELP = ("skips the repository's hooks, where its regression tests run before each commit. "
             "Fix what the hook reports; if a test must change, ask the owner.")
# Quoted text that is itself run as a command.
NESTED = re.compile(r"\b(?:ssh\b[^;&|\n'\"]*|(?:ba|z|da)?sh\s+(?:-\w+\s+)*-c\s+)('[^']*'|\"(?:\\.|[^\"\\])*\")")
# A heredoc: the line that opens it, and its body up to the delimiter.
HEREDOC = re.compile(r"^(?P<line>[^\n]*?<<-?[ \t]*(?P<q>['\"]?)(?P<tag>\w+)(?P=q)[^\n]*)\n(?P<body>.*?)^[ \t]*(?P=tag)[ \t]*$", re.M | re.S)
# Heredocs fed to these are commands; to anything else (cat, git commit -F -, python) they are text.
SHELL_INPUT = re.compile(r"(?:^|[;&|]\s*)(?:ba|z|da)?sh\b|\bssh\b")

PROCS = "~/.claude/bin/procs.sh"
PROCESS_HELP = (f"matches its own calling shell (it kills or counts its caller). Use {PROCS} "
                "list|count|kill [-SIG] PATTERN, or alive PID...; on another machine: "
                f"ssh HOST bash -s -- kill PATTERN < {PROCS}. Better: keep the PIDs you start ($!).")

# (compiled regex, message): matched against the command with text heredocs removed.
EXTRA_RULES: list[tuple[re.Pattern, str]] = []


def without_text_heredocs(command: str) -> str:
    return HEREDOC.sub(lambda m: m.group(0) if SHELL_INPUT.search(m.group("line")) else m.group("line"), command)


def process_tool(command: str) -> str | None:
    unquoted = QUOTED.sub(lambda m: " " * len(m.group()), command)
    found = PROCESS_TOOL.search(unquoted)
    if found:
        return found.group(1)
    if HOOK_SKIP.search(unquoted):
        return "git-hooks"
    for nested in NESTED.finditer(command):
        inner = process_tool(nested.group(1)[1:-1])
        if inner:
            return inner
    return None


def refusal(command: str) -> str | None:
    command = without_text_heredocs(command)
    tool = process_tool(command)
    if tool == "git-hooks":
        return f"git-hooks: this {HOOK_HELP}"
    if tool:
        return f"{tool} {PROCESS_HELP}"
    for rule, why in EXTRA_RULES:
        if rule.search(command):
            return why
    return None


if __name__ == "__main__":
    if "--test" in sys.argv[1:]:
        cases = json.loads((Path(__file__).parent / "bash-guards.cases.json").read_text())
        wrong = [cmd for want, cmd in cases if bool(refusal(cmd)) != (want == 2)]
        print(f"{len(cases) - len(wrong)}/{len(cases)} cases right" + "".join(f"\nwrong: {c!r}" for c in wrong))
        sys.exit(1 if wrong else 0)
    why = refusal(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
    if why:
        # One line per block, so guards that never fire can be pruned (README, "Pruning").
        try:
            import time
            with open(Path.home() / ".claude" / "toolkit-hits.log", "a") as log:
                log.write(f"{time.strftime('%Y-%m-%d')}\tbash-guards\t{why.split()[0]}\n")
        except OSError:
            pass
        print(f"Blocked: {why}", file=sys.stderr)
        sys.exit(2)
