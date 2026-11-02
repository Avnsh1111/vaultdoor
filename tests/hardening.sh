#!/bin/bash
# Tests what the macOS protections really do, using a signed binary and a
# throwaway Keychain item. Runs without showing any dialog, and removes the item.
set -uo pipefail
cd "$(dirname "$0")/.."
SERVICE=local.vault.selftest
T=$(mktemp -d)
cleanup() { security delete-generic-password -s "$SERVICE" -a default >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
export VAULT_TEST_HOME=$T/home
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

scripts/build.sh --keychain-test >/dev/null
BIN=$PWD/build/vaultdoor-keychain-test
swiftc -framework Security tests/keychain_probe.swift -o "$T/probe" 2>/dev/null
codesign --force -s - "$T/probe"
clang -dynamiclib tests/inject_probe.c -o "$T/inject.dylib"
codesign --force -s - "$T/inject.dylib"

security delete-generic-password -s "$SERVICE" -a default >/dev/null 2>&1

echo "code signature"
sig=$(codesign -dv "$BIN" 2>&1)
grep -q 'flags=.*runtime' <<<"$sig" && ok "hardened runtime is on" || bad "hardened runtime is off" "$sig"

echo "keychain"
[[ $("$BIN" __master-create) == created ]] && ok "the vault binary can create its key" || bad "could not create the key"
[[ $("$BIN" __master-read) == read-ok ]] && ok "the vault binary can read its key" || bad "could not read the key"
out=$("$T/probe" "$SERVICE"); [[ $out == refused* ]] && ok "another program is refused ($out)" || bad "another program read the key" "$out"

echo "app guard hook"
P=$T/proj; mkdir -p "$P"
printf '{"version":1,"projects":[{"id":"p","name":"p","path":"%s","secretIDs":[],"disabledApps":["blocked"],"actions":[]}]}' "$P" > "$T/seed.json"
"$BIN" __seed "$T/seed.json"
printf '{"tool_name":"mcp__blocked__send","cwd":"%s"}' "$P" > "$T/call.json"
"$BIN" hook < "$T/call.json" 2>/dev/null; rc=$?
[[ $rc == 2 ]] && ok "the signed binary reads the vault and blocks the app" || bad "signed binary did not block" "exit $rc"
# A build the Keychain has not approved yet, as after every update.
cp "$BIN" "$T/updated"; codesign --force -s - -o runtime --identifier local.vault.updated "$T/updated" 2>/dev/null
start=$SECONDS
"$T/updated" hook < "$T/call.json" >/dev/null 2>&1 & hp=$!
for _ in $(seq 1 50); do kill -0 "$hp" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$hp" 2>/dev/null; then kill "$hp"; bad "the hook waited on a Keychain prompt"; else wait "$hp"; rc=$?; [[ $rc == 0 ]] && ok "an unapproved build lets the call through, with no prompt" || bad "wrong exit from an unapproved build" "exit $rc"; fi

echo "code injection"
out=$(DYLD_INSERT_LIBRARIES="$T/inject.dylib" "$BIN" help 2>&1)
grep -q INJECTED <<<"$out" && bad "a library was injected into the vault" || ok "injected library is ignored"
# Same library against an unprotected copy, to prove the probe itself works.
cp "$BIN" "$T/plain"; codesign --remove-signature "$T/plain" 2>/dev/null; codesign --force -s - "$T/plain" 2>/dev/null
out=$(DYLD_INSERT_LIBRARIES="$T/inject.dylib" "$T/plain" help 2>&1)
grep -q INJECTED <<<"$out" && ok "the same library does load into an unprotected copy" || bad "probe did not load even without protection"

echo
echo "passed $pass, failed $fail"
[[ $fail == 0 ]]
