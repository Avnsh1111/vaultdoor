#!/bin/bash
# Sets up VaultDoor on this Mac. Safe to run again: it rebuilds only when the code changed.
#
#   scripts/setup.sh           app, vaultdoor command and skill
#   scripts/setup.sh --hook    also let the dashboard's app switches block AI tool calls
#   scripts/setup.sh --force   rebuild even if nothing changed
set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

WITH_HOOK=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --hook) WITH_HOOK=1 ;;
    --force) FORCE=1 ;;
    *) die "Unknown option: $arg (use --hook or --force)." ;;
  esac
done

[[ $(uname) == Darwin ]] || die "VaultDoor runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[[ $major -ge 13 ]] || die "VaultDoor needs macOS 13 or newer. This Mac has $(sw_vers -productVersion)."
xcode-select -p >/dev/null 2>&1 || die "VaultDoor is built on your Mac and needs Apple's command line tools. Run: xcode-select --install   Then run this again."

SOURCE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SKILL="$HOME/.agents/skills/vaultdoor"
APP="$HOME/Applications/VaultDoor.app"
BIN="$APP/Contents/MacOS/vaultdoor"
LINK="$HOME/.local/bin/vaultdoor"
DATA="$HOME/Library/Application Support/VaultDoor"
OLD_DATA="$HOME/Library/Application Support/Vault"
OLD_APP="$HOME/Applications/Vault.app"

# Moves an install from when this tool was called Vault. Stored data keeps working.
if [[ -e $OLD_APP ]]; then
  pkill -f "$OLD_APP/Contents/MacOS/vault" 2>/dev/null || true
  rm -rf "$OLD_APP"
  echo "Removed: the old Vault.app"
fi
if [[ -f $OLD_DATA/vault.enc && ! -e $DATA ]]; then
  mv "$OLD_DATA" "$DATA"
  echo "Moved:   your vault to $DATA"
fi
if [[ -L $HOME/.local/bin/vault && $(readlink "$HOME/.local/bin/vault") == *"Vault.app/Contents/MacOS/vault" ]]; then
  rm -f "$HOME/.local/bin/vault"
fi

# A stable copy of the skill, so the folder this ran from can be deleted afterwards.
mkdir -p "$SKILL"
if [[ $(cd "$SKILL" && pwd -P) != "$SOURCE" ]]; then
  rsync -a --delete --exclude .git --exclude build --exclude .DS_Store "$SOURCE/" "$SKILL/"
fi
echo "Skill:   $SKILL"

mkdir -p "$DATA"
chmod 700 "$DATA"
stamp="$DATA/installed-source"
hash=$(cd "$SKILL" && find Sources web scripts/build.sh -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)

# Every rebuild makes macOS ask about the Keychain again, so skip it when nothing changed.
if [[ $FORCE == 0 && -x $BIN && -f $stamp && $(cat "$stamp") == "$hash" ]]; then
  echo "App:     already up to date"
  built=0
else
  echo "Building, which takes a minute or two..."
  build_dir=$(mktemp -d)
  trap 'rm -rf "$build_dir"' EXIT
  if ! VAULT_BUILD_DIR="$build_dir" "$SKILL/scripts/build.sh" >"$build_dir/log" 2>&1; then
    grep -E 'error:' "$build_dir/log" >&2 || cat "$build_dir/log" >&2
    die "The build failed."
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$APP"
  cp -R "$build_dir/VaultDoor.app" "$APP"
  codesign --verify --deep "$APP"
  printf '%s\n' "$hash" > "$stamp"
  echo "App:     $APP"
  built=1
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$LINK"
echo "Command: $LINK"

# Make the skill available to each AI tool found on this Mac.
for tool in "$HOME/.claude" "$HOME/.codex" "$HOME/.cursor" "$HOME/.config/opencode"; do
  [[ -d $tool ]] || continue
  old="$tool/skills/vault"
  if [[ -L $old && $(readlink "$old") == *"/.agents/skills/vault" ]]; then rm -f "$old"; fi
  target="$tool/skills/vaultdoor"
  [[ -e $target && ! -L $target ]] && continue
  mkdir -p "$tool/skills"
  ln -sfn "$SKILL" "$target"
  echo "Linked:  $target"
done
if [[ -f $HOME/.agents/skills/vault/SKILL.md && $(find "$HOME/.agents/skills/vault" -type f | wc -l | tr -d ' ') == 1 ]] && grep -q '^name: vault$' "$HOME/.agents/skills/vault/SKILL.md"; then
  rm -f "$HOME/.agents/skills/vault/SKILL.md"
  rmdir "$HOME/.agents/skills/vault"
fi

# Merged by script and never printed: permission rules in this file can hold secrets.
WITH_HOOK=$WITH_HOOK /usr/bin/python3 -I - <<'PY'
import json, os, shutil, sys
path = os.path.join(os.path.expanduser('~'), '.claude', 'settings.json')
wanted = os.environ['WITH_HOOK'] == '1'
if not os.path.isdir(os.path.dirname(path)):
    if wanted:
        print('Hook:    skipped, no supported AI tool settings found')
    sys.exit(0)
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
command = '"$HOME/.local/bin/vaultdoor" hook'
old = '"$HOME/.local/bin/vault" hook'
entries = (data.get('hooks') or {}).get('PreToolUse') or []
hooks = [h for e in entries for h in e.get('hooks', [])]
changed = False
for h in hooks:
    if h.get('command') == old:
        h['command'] = command
        changed = True
present = any(h.get('command') == command for h in hooks)
if wanted and not present:
    # Keep the very first backup: a later run must not replace it with a changed copy.
    if os.path.exists(path) and not os.path.exists(path + '.before-vaultdoor'):
        shutil.copy2(path, path + '.before-vaultdoor')
    data.setdefault('hooks', {}).setdefault('PreToolUse', []).append(
        {'matcher': 'mcp__.*', 'hooks': [{'type': 'command', 'command': command, 'timeout': 5}]})
    changed = True
if changed:
    temp = path + '.tmp-vaultdoor'
    with open(temp, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')
    os.chmod(temp, os.stat(path).st_mode if os.path.exists(path) else 0o600)
    os.replace(temp, path)
    print('Hook:    added to ' + path)
elif wanted:
    print('Hook:    already added')
PY

echo
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Add this to your shell profile so AI tools can find it:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
command -v sshpass >/dev/null || echo "For servers that log in with a password, also run:  brew install sshpass"
if [[ $built == 1 ]] && pgrep -f "$BIN" >/dev/null; then
  echo "VaultDoor is open. Quit and reopen it to use this version."
fi
echo "Open it with:  vaultdoor dashboard"
if [[ $built == 1 ]]; then
  echo "If macOS asks about the Keychain, enter your Mac password and choose Always Allow."
fi
