#!/bin/bash
# install.sh: installs the toolkit for every Claude Code project and session on this machine.
#
#   curl -fsSL https://raw.githubusercontent.com/ddifofeu/claude-code-toolkit/main/install.sh | bash
#   ./install.sh                     # from a clone
#   TOOLKIT_REPO=you/your-fork ./install.sh   # keep your own copy in sync instead
#
# Puts in ~/.claude: CLAUDE.md (the working rules; an existing one is kept as CLAUDE.md.bak-*),
# bin/procs.sh, bin/supervise.sh, bin/budget-scan.py, bin/statusline.sh, bin/usage-advisor.py, hooks/bash-guards.py, hooks/heavy-guard.py,
# tracker/tracker.py and tracker/pre-commit, and the sync script. Adds four hooks to
# ~/.claude/settings.json, keeping all else (backup first): SessionStart refreshes the files from
# GitHub; PreToolUse (Bash) runs the guard and the heavy-step guard (which allows everything until
# ~/.claude/heavy-guard.json exists); Stop runs the promise guard.
# Running it again changes nothing already installed; it adds what a newer toolkit brings.
set -euo pipefail
SOURCE=${TOOLKIT_REPO:-ddifofeu/claude-code-toolkit}
command -v python3 >/dev/null || { echo "python3 is needed" >&2; exit 1; }
mkdir -p ~/.claude/hooks ~/.claude/bin ~/.claude/tracker
echo "$SOURCE" > ~/.claude/toolkit-source
stamp=$(date +%Y%m%d-%H%M%S)

here=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/hooks/bash-guards.py" ]; then   # from a clone
    if [ -f ~/.claude/CLAUDE.md ] && ! cmp -s "$here/CLAUDE.md" ~/.claude/CLAUDE.md; then
        cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak-$stamp
    fi
    cp "$here/CLAUDE.md" ~/.claude/CLAUDE.md
    install -m 755 "$here/bin/procs.sh" ~/.claude/bin/procs.sh
    install -m 755 "$here/bin/supervise.sh" ~/.claude/bin/supervise.sh
    install -m 755 "$here/bin/budget-scan.py" ~/.claude/bin/budget-scan.py
    install -m 755 "$here/bin/statusline.sh" ~/.claude/bin/statusline.sh
    install -m 755 "$here/bin/usage-advisor.py" ~/.claude/bin/usage-advisor.py
    install -m 755 "$here/hooks/bash-guards.py" ~/.claude/hooks/bash-guards.py
    install -m 644 "$here/hooks/bash-guards.cases.json" ~/.claude/hooks/bash-guards.cases.json
    install -m 755 "$here/hooks/promise-guard.py" ~/.claude/hooks/promise-guard.py
    install -m 644 "$here/hooks/promise-guard.cases.json" ~/.claude/hooks/promise-guard.cases.json
    install -m 755 "$here/hooks/away-guard.py" ~/.claude/hooks/away-guard.py
    install -m 755 "$here/hooks/heavy-guard.py" ~/.claude/hooks/heavy-guard.py
    install -m 644 "$here/hooks/heavy-guard.cases.json" ~/.claude/hooks/heavy-guard.cases.json
    install -m 755 "$here/tracker/tracker.py" ~/.claude/tracker/tracker.py
    install -m 755 "$here/tracker/pre-commit" ~/.claude/tracker/pre-commit
    install -m 755 "$here/sync.sh" ~/.claude/hooks/sync-toolkit.sh
else                                                          # piped from curl
    [ -f ~/.claude/CLAUDE.md ] && cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak-$stamp
    curl -fsSL "https://raw.githubusercontent.com/$SOURCE/main/sync.sh" -o ~/.claude/hooks/sync-toolkit.sh
    chmod 755 ~/.claude/hooks/sync-toolkit.sh
    bash ~/.claude/hooks/sync-toolkit.sh
fi
for f in CLAUDE.md bin/procs.sh bin/supervise.sh bin/budget-scan.py hooks/bash-guards.py hooks/promise-guard.py hooks/away-guard.py hooks/heavy-guard.py tracker/tracker.py; do
    [ -s ~/.claude/$f ] || { echo "missing ~/.claude/$f" >&2; exit 1; }
done

python3 - "$stamp" <<'EOF'
import json, os, shutil, sys
path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
    shutil.copy(path, f"{path}.bak-{sys.argv[1]}")
hooks = settings.setdefault("hooks", {})
wanted = [  # (event, group): one group per hook, so a hook added later reaches existing installs
    ("SessionStart", {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/sync-toolkit.sh", "timeout": 60}]}),
    ("PreToolUse", {"matcher": "Bash", "hooks": [{"type": "command",
                    "command": "python3 ~/.claude/hooks/bash-guards.py", "timeout": 10}]}),
    ("PreToolUse", {"matcher": "Bash", "hooks": [{"type": "command",
                    "command": "python3 ~/.claude/hooks/heavy-guard.py", "timeout": 10}]}),
    ("Stop", {"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/promise-guard.py", "timeout": 10}]}),
    ("UserPromptSubmit", {"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/away-guard.py prompt", "timeout": 10}]}),
    ("PreToolUse", {"matcher": "AskUserQuestion", "hooks": [{"type": "command",
                    "command": "python3 ~/.claude/hooks/away-guard.py ask", "timeout": 10}]}),
]
for event, group in wanted:
    groups = hooks.setdefault(event, [])
    command = group["hooks"][0]["command"]
    if not any(h.get("command") == command for g in groups for h in g.get("hooks", [])):
        groups.append(group)
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"{path}: SessionStart sync, PreToolUse guard and heavy-guard, Stop promise-guard, away-guard hooks present")
EOF
python3 ~/.claude/hooks/bash-guards.py --test
python3 ~/.claude/hooks/promise-guard.py --test
python3 ~/.claude/hooks/away-guard.py --test
python3 ~/.claude/hooks/heavy-guard.py --test
echo "installed from $SOURCE; new Claude Code sessions use it"
