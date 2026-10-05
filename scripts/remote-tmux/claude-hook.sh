#!/bin/sh
# Forwards one Claude Code hook event to the cmux app mirroring this tmux
# session over ssh-tmux (`tmux -CC`).
#
# That transport has no socket relay back to the Mac, but tmux copies every
# byte a pane writes into the control stream verbatim. So this script writes
# the event to the pane's terminal as
#
#   ESC ] 777;cmux-hook;<base64 {"event","session_id","cwd"}> BEL
#
# and cmux strips it from the mirrored output and updates that pane's agent
# state (RemoteTmuxPaneHookEvent in the app). Ordinary tmux clients drop the
# unknown OSC, and outside tmux the script does nothing.
#
# Usage, from ~/.claude/settings.json:  claude-hook.sh <HookEventName>
# Reads the hook JSON on stdin. Always exits 0 so it can never block Claude.
# Installed by scripts/remote-tmux/install-claude-hooks.sh.

event=${1:-}
case $event in
  SessionStart|SessionEnd|UserPromptSubmit|PreToolUse|PostToolUse|PostToolUseFailure|Stop|Notification|PermissionRequest) ;;
  *) exit 0 ;;
esac

# Outside tmux there is no pane to write to; just drain stdin so Claude never
# writes into a closed pipe.
if [ -z "${TMUX:-}" ]; then
  cat >/dev/null
  exit 0
fi

# The first top-level `"key": "<JSON string>"` members for session_id and cwd,
# verbatim (escapes intact), so they can be spliced into the forwarded JSON
# as is. One awk pass over the first block only (session_id and cwd lead
# Claude's payload); the rest is drained unread. Runs on every tool call, so
# it keeps the process count low.
fields=$({ dd bs=65536 count=1 2>/dev/null; cat >/dev/null; } | awk '
  !s && match($0, /"session_id"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/) { s = substr($0, RSTART, RLENGTH) }
  !c && match($0, /"cwd"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/) { c = substr($0, RSTART, RLENGTH) }
  END { print s; print c }
')
# `$(…)` drops the trailing newline, so an empty cwd leaves no separator.
session=${fields%%"
"*}
case $fields in
  *"
"*) cwd=${fields#*"
"} ;;
  *) cwd= ;;
esac
[ -n "$session" ] || exit 0

json="{\"event\":\"$event\",$session${cwd:+,$cwd}}"
payload=$(printf '%s' "$json" | base64 | tr -d '\n')
sequence=$(printf '\033]777;cmux-hook;%s\007' "$payload")

# The pane is normally the hook's controlling terminal; fall back to the
# pane's tty path when Claude runs hooks without one.
{
  printf '%s' "$sequence" >/dev/tty \
    || { pane_tty=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_tty}') \
         && [ -c "$pane_tty" ] && printf '%s' "$sequence" >"$pane_tty"; }
} 2>/dev/null

exit 0
