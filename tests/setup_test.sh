#!/bin/bash
# Runs setup as a brand-new user and as someone upgrading, inside throwaway home
# folders. Never touches the real install, vault or AI settings.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | cut -c1-300; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing: $2 in: $3"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "found: $2"; else ok "$1"; fi; }
exists() { if [[ -e $2 ]]; then ok "$1"; else bad "$1" "missing $2"; fi; }
gone() { if [[ ! -e $2 && ! -L $2 ]]; then ok "$1"; else bad "$1" "still there: $2"; fi; }

echo "a new user"
H=$T/new; mkdir -p "$H/.claude" "$H/.codex"
printf '{"model":"x","permissions":{"allow":["Read"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo bye"}]}]}}\n' > "$H/.claude/settings.json"
cp "$H/.claude/settings.json" "$T/original.json"
# Run from a folder that is deleted afterwards, as with a download.
mkdir -p "$T/download"
rsync -a --exclude .git --exclude build --exclude .DS_Store "$ROOT/" "$T/download/"
out=$(env HOME="$H" bash "$T/download/scripts/setup.sh" --hook 2>&1); rc=$?
[[ $rc == 0 ]] && ok "setup succeeds" || bad "setup failed" "$out"
hasnt "setup output has no compiler noise" "warning:" "$out"
rm -rf "$T/download"
exists "app is installed" "$H/Applications/VaultDoor.app/Contents/MacOS/vaultdoor"
codesign -dv "$H/Applications/VaultDoor.app" 2>"$T/sig"; has "app has hardened runtime" "runtime" "$(cat "$T/sig")"
exists "skill is installed" "$H/.agents/skills/vaultdoor/SKILL.md"
exists "skill keeps its code after the download is deleted" "$H/.agents/skills/vaultdoor/Sources/main.swift"
gone "no build leftovers in the skill" "$H/.agents/skills/vaultdoor/build"
[[ $(readlink "$H/.claude/skills/vaultdoor") == "$H/.agents/skills/vaultdoor" ]] && ok "skill is linked for the first AI tool" || bad "first link wrong"
[[ $(readlink "$H/.codex/skills/vaultdoor") == "$H/.agents/skills/vaultdoor" ]] && ok "skill is linked for the second AI tool" || bad "second link wrong"
gone "tools that are not installed are left alone" "$H/.cursor"
out=$("$H/.local/bin/vaultdoor" help 2>&1); has "the command runs" "use stored credentials" "$out"
out=$(printf '{"tool_name":"mcp__x__y","cwd":"/tmp"}' | "$H/.local/bin/vaultdoor" hook 2>&1; echo "exit=$?"); has "the hook runs without stopping for a prompt" "exit=0" "$out"
python3 -I - "$H/.claude" "$T/original.json" <<'PY'; [[ $? == 0 ]] && ok "the hook is added and every other setting is unchanged" || bad "settings were changed wrongly"
import json, sys
d, orig = sys.argv[1:]
s = json.load(open(d + '/settings.json')); o = json.load(open(orig)); b = json.load(open(d + '/settings.json.before-vaultdoor'))
assert b == o
assert [h['command'] for e in s['hooks']['PreToolUse'] for h in e['hooks']] == ['"$HOME/.local/bin/vaultdoor" hook']
s['hooks'].pop('PreToolUse')
assert s == o
PY

echo "running it again"
before=$(stat -f '%m' "$H/Applications/VaultDoor.app/Contents/MacOS/vaultdoor")
SECONDS=0
out=$(env HOME="$H" bash "$H/.agents/skills/vaultdoor/scripts/setup.sh" --hook 2>&1); rc=$?
[[ $rc == 0 ]] && ok "a second run succeeds" || bad "second run failed" "$out"
has "nothing is rebuilt when nothing changed" "already up to date" "$out"
[[ $(stat -f '%m' "$H/Applications/VaultDoor.app/Contents/MacOS/vaultdoor") == "$before" ]] && ok "the app is untouched, so no new Keychain prompt" || bad "the app was replaced"
hasnt "no Keychain warning when nothing changed" "Keychain" "$out"
has "the hook is not added twice" "already added" "$out"
python3 -I - "$H/.claude" "$T/original.json" <<'PY'; [[ $? == 0 ]] && ok "the first backup is kept" || bad "the first backup was replaced"
import json, sys
assert json.load(open(sys.argv[1] + '/settings.json.before-vaultdoor')) == json.load(open(sys.argv[2]))
PY

echo "setup without the hook"
H2=$T/nohook; mkdir -p "$H2/.claude"; printf '{"model":"x"}\n' > "$H2/.claude/settings.json"
cp -R "$H/.agents" "$H2/.agents" 2>/dev/null
out=$(env HOME="$H2" bash "$ROOT/scripts/setup.sh" 2>&1); rc=$?
[[ $rc == 0 ]] && ok "setup succeeds" || bad "setup failed" "$out"
[[ $(cat "$H2/.claude/settings.json") == '{"model":"x"}' ]] && ok "AI settings are not touched" || bad "AI settings changed without --hook"

echo "upgrading from the old name"
H3=$T/old; mkdir -p "$H3/.claude/skills" "$H3/.agents/skills/vault" "$H3/.local/bin" "$H3/Applications/Vault.app/Contents/MacOS" "$H3/Library/Application Support/Vault"
printf '#!/bin/bash\n' > "$H3/Applications/Vault.app/Contents/MacOS/vault"; chmod +x "$H3/Applications/Vault.app/Contents/MacOS/vault"
ln -s "$H3/Applications/Vault.app/Contents/MacOS/vault" "$H3/.local/bin/vault"
printf -- '---\nname: vault\n---\n' > "$H3/.agents/skills/vault/SKILL.md"
ln -s "$H3/.agents/skills/vault" "$H3/.claude/skills/vault"
printf 'encrypted-bytes' > "$H3/Library/Application Support/Vault/vault.enc"
printf '{"hooks":{"PreToolUse":[{"matcher":"mcp__.*","hooks":[{"type":"command","command":"\\"$HOME/.local/bin/vault\\" hook","timeout":5}]}],"Stop":[]},"model":"x"}\n' > "$H3/.claude/settings.json"
out=$(env HOME="$H3" bash "$ROOT/scripts/setup.sh" 2>&1); rc=$?
[[ $rc == 0 ]] && ok "the upgrade succeeds" || bad "upgrade failed" "$out"
[[ $(cat "$H3/Library/Application Support/VaultDoor/vault.enc" 2>/dev/null) == encrypted-bytes ]] && ok "the stored vault moves across unchanged" || bad "the vault did not move"
gone "the old app is removed" "$H3/Applications/Vault.app"
gone "the old command is removed" "$H3/.local/bin/vault"
gone "the old skill link is removed" "$H3/.claude/skills/vault"
gone "the old skill is removed" "$H3/.agents/skills/vault"
exists "the new skill is linked" "$H3/.claude/skills/vaultdoor"
out=$(cat "$H3/.claude/settings.json"); has "the old hook now uses the new command" '.local/bin/vaultdoor' "$out"; hasnt "the old hook command is gone" '.local/bin/vault\"' "$out"
python3 -I -c "
import json,sys
s=json.load(open(sys.argv[1])); assert s['model']=='x' and len(s['hooks']['PreToolUse'])==1" "$H3/.claude/settings.json"; [[ $? == 0 ]] && ok "other settings survive the upgrade" || bad "upgrade damaged settings"

echo "not overwriting someone else's folder"
H4=$T/mine; mkdir -p "$H4/.claude/skills/vaultdoor"; printf 'mine' > "$H4/.claude/skills/vaultdoor/note"
cp -R "$H/.agents" "$H4/.agents" 2>/dev/null
env HOME="$H4" bash "$ROOT/scripts/setup.sh" >/dev/null 2>&1
[[ $(cat "$H4/.claude/skills/vaultdoor/note" 2>/dev/null) == mine ]] && ok "an existing real folder is left alone" || bad "a real folder was overwritten"

echo "uninstalling"
mkdir -p "$H/Library/Application Support/VaultDoor"; printf 'keep' > "$H/Library/Application Support/VaultDoor/vault.enc"
out=$(env HOME="$H" bash "$H/.agents/skills/vaultdoor/scripts/uninstall.sh" 2>&1); rc=$?
[[ $rc == 0 ]] && ok "uninstall succeeds" || bad "uninstall failed" "$out"
gone "the app is gone" "$H/Applications/VaultDoor.app"; gone "the command is gone" "$H/.local/bin/vaultdoor"; gone "the skill is gone" "$H/.agents/skills/vaultdoor"; gone "the skill link is gone" "$H/.claude/skills/vaultdoor"
exists "the stored vault is kept by default" "$H/Library/Application Support/VaultDoor/vault.enc"
python3 -I - "$H/.claude" "$T/original.json" <<'PY'; [[ $? == 0 ]] && ok "AI settings return to how they were" || bad "the hook was not removed cleanly"
import json, sys
s = json.load(open(sys.argv[1] + '/settings.json')); o = json.load(open(sys.argv[2]))
assert s == o, s
PY

echo
echo "passed $pass, failed $fail"
[[ $fail == 0 ]]
