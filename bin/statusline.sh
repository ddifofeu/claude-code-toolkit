#!/bin/bash
# statusline.sh: a status line that keeps Claude Code's own feed and shows the plan's usage.
# Claude Code pipes a JSON document to the status line command on every refresh: the plan's limits
# (rate_limits.five_hour / seven_day: used_percentage, resets_at), the model, the effort, the session's
# cost. This saves the latest copy to ~/.cache/claude-statusline.json (read by usage-advisor.py) and
# prints user@host:dir, then "5h 9% · 7d 85% · Opus · medium".
# settings.json: "statusLine": { "type": "command", "command": "~/.claude/bin/statusline.sh" }
input=$(cat)
mkdir -p "$HOME/.cache" && printf '%s' "$input" > "$HOME/.cache/claude-statusline.json"
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
cwd="${cwd/#$HOME/~}"
lim=$(printf '%s' "$input" | jq -r '[(.rate_limits.five_hour.used_percentage // empty | "5h \(.)%"), (.rate_limits.seven_day.used_percentage // empty | "7d \(.)%"), (.model.display_name // empty), (.effort.level // empty)] | join(" · ")')
printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m  \033[02m%s\033[00m' "$(whoami)" "$(hostname -s)" "$cwd" "$lim"
