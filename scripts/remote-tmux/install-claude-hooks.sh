#!/usr/bin/env bash
# Installs (or removes) the cmux ssh-tmux Claude hooks on a remote host.
#
#   scripts/remote-tmux/install-claude-hooks.sh <ssh-destination>
#   scripts/remote-tmux/install-claude-hooks.sh --uninstall <ssh-destination>
#
# Copies claude-hook.sh to ~/.cmux/tmux-mirror/ on the host and registers it
# for Claude's lifecycle events in ~/.claude/settings.json, after saving a
# timestamped backup next to it. Re-running replaces cmux's own entries and
# leaves every other hook untouched. Needs python3 on the host for the JSON
# merge. Claude sessions already running pick the hooks up on restart.
set -euo pipefail

mode=install
if [[ "${1:-}" == "--uninstall" ]]; then
  mode=uninstall
  shift
fi
dest=${1:-}
if [[ -z "$dest" ]]; then
  echo "usage: $0 [--uninstall] <ssh-destination>" >&2
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)

if [[ "$mode" == install ]]; then
  ssh "$dest" 'mkdir -p "$HOME/.cmux/tmux-mirror" \
    && cat > "$HOME/.cmux/tmux-mirror/claude-hook.sh.tmp" \
    && chmod 755 "$HOME/.cmux/tmux-mirror/claude-hook.sh.tmp" \
    && mv "$HOME/.cmux/tmux-mirror/claude-hook.sh.tmp" "$HOME/.cmux/tmux-mirror/claude-hook.sh"' \
    < "$here/claude-hook.sh"
fi

ssh "$dest" "command -v python3 >/dev/null || { echo 'python3 is required on the host' >&2; exit 1; }; python3 - $mode" <<'PY'
import json, os, shutil, sys, time

mode = sys.argv[1]
marker = "/.cmux/tmux-mirror/claude-hook.sh"
events = {
    "SessionStart": None,
    "SessionEnd": None,
    "UserPromptSubmit": None,
    "PreToolUse": "*",
    "PostToolUse": "*",
    "PostToolUseFailure": "*",
    "Stop": None,
    "Notification": None,
    "PermissionRequest": "*",
}

path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
    backup = "%s.cmux-backup-%d" % (path, int(time.time()))
    shutil.copy2(path, backup)
    print("backup: " + backup)

hooks = settings.get("hooks") or {}
# Drop cmux's own entries first so a re-run replaces rather than duplicates.
for name in list(hooks):
    kept = []
    for group in hooks[name]:
        commands = [h for h in group.get("hooks", []) if marker not in h.get("command", "")]
        if commands:
            group = dict(group, hooks=commands)
            kept.append(group)
    if kept:
        hooks[name] = kept
    else:
        del hooks[name]

if mode == "install":
    for name, matcher in events.items():
        group = {"hooks": [{
            "type": "command",
            "command": '"$HOME%s" %s' % (marker, name),
            "timeout": 5,
        }]}
        if matcher is not None:
            group["matcher"] = matcher
        hooks.setdefault(name, []).append(group)

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".cmux-tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("%sed cmux ssh-tmux Claude hooks in %s" % (mode, path))
PY
