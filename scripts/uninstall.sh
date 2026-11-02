#!/bin/bash
# Removes VaultDoor from this Mac. Your stored vault is kept unless you pass --purge.
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

DATA="$HOME/Library/Application Support/VaultDoor"
APP="$HOME/Applications/VaultDoor.app"

pkill -f "$APP/Contents/MacOS/vaultdoor" 2>/dev/null || true
rm -rf "$APP"
rm -f "$HOME/.local/bin/vaultdoor"
for tool in "$HOME/.claude" "$HOME/.codex" "$HOME/.cursor" "$HOME/.config/opencode"; do
  link="$tool/skills/vaultdoor"
  if [[ -L $link ]]; then rm -f "$link"; fi
done

# Merged by script and never printed: permission rules in this file can hold secrets.
/usr/bin/python3 -I - <<'PY'
import json, os
path = os.path.join(os.path.expanduser('~'), '.claude', 'settings.json')
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
    hooks = data.get('hooks') or {}
    entries = hooks.get('PreToolUse') or []
    kept = []
    for entry in entries:
        entry['hooks'] = [h for h in entry.get('hooks', []) if h.get('command') != '"$HOME/.local/bin/vaultdoor" hook']
        if entry['hooks']:
            kept.append(entry)
    if len(kept) != len(entries):
        if kept:
            hooks['PreToolUse'] = kept
        else:
            hooks.pop('PreToolUse', None)
        temp = path + '.tmp-vaultdoor'
        with open(temp, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write('\n')
        os.chmod(temp, os.stat(path).st_mode)
        os.replace(temp, path)
        print('Hook removed.')
PY

if [[ $PURGE == 1 ]]; then
  printf 'This permanently deletes every stored password and key. Type DELETE to confirm: '
  read -r answer
  if [[ $answer == DELETE ]]; then
    rm -rf "$DATA"
    security delete-generic-password -s local.vault.master -a default >/dev/null 2>&1 || true
    echo "Vault deleted."
  else
    echo "Vault kept."
  fi
else
  echo "Your vault is kept in: $DATA"
  echo "To delete it as well, run this script with --purge."
fi

rm -rf "$HOME/.agents/skills/vaultdoor"
echo "VaultDoor removed."
