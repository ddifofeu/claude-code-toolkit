#!/bin/bash
# sync.sh: refreshes the toolkit's files in ~/.claude from its GitHub repository (the one named
# in ~/.claude/toolkit-source, set by install.sh). Run by a SessionStart hook; offline it keeps
# the installed copies. It never fails a session.
SOURCE=$(cat ~/.claude/toolkit-source 2>/dev/null || echo ddifofeu/claude-code-toolkit)
FILES="CLAUDE.md bin/procs.sh hooks/bash-guards.py hooks/bash-guards.cases.json hooks/promise-guard.py hooks/promise-guard.cases.json tracker/tracker.py tracker/pre-commit sync.sh"
fetch() {  # fetch PATH > out: raw file from the default branch
    curl -fsSL --max-time 10 "https://raw.githubusercontent.com/$SOURCE/main/$1" 2>/dev/null ||
        { command -v gh >/dev/null && timeout 10 gh api "repos/$SOURCE/contents/$1" -H "Accept: application/vnd.github.raw" 2>/dev/null; }
}
for f in $FILES; do
    dest=~/.claude/$f
    [ "$f" = sync.sh ] && dest=~/.claude/hooks/sync-toolkit.sh
    tmp=$(mktemp) || continue
    if fetch "$f" > "$tmp" && [ -s "$tmp" ] && ! cmp -s "$tmp" "$dest"; then
        mkdir -p "$(dirname "$dest")"
        case "$f" in *.sh|*.py|*/pre-commit) chmod 755 "$tmp" ;; *) chmod 644 "$tmp" ;; esac
        mv "$tmp" "$dest" && echo "toolkit: updated $dest"
    else
        rm -f "$tmp"
    fi
done
exit 0
