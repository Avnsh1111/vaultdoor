#!/bin/bash
# End to end against a real SSH server: a throwaway sshd on this Mac, running as
# you and listening only on 127.0.0.1, that accepts one test key. Runs the login
# check, `vaultdoor ssh`, an approved deploy over ssh and redaction with the real
# ssh and sshpass. Uses the test build and a throwaway vault, and keeps the test
# server's host key out of ~/.ssh.
set -uo pipefail
cd "$(dirname "$0")/.."
V=$PWD/build/vaultdoor-test
[[ -x $V ]] || scripts/build.sh --test >/dev/null

T=$(mktemp -d)
cleanup() { [[ -f $T/sshd.pid ]] && kill "$(cat "$T/sshd.pid")" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | cut -c1-300; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing: $2 in: $3"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "leaked: $2"; else ok "$1"; fi; }
code() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted exit $2, got $3"; fi; }

before=$(shasum -a 256 ~/.ssh/known_hosts 2>/dev/null | cut -d' ' -f1)
PORT=$((20000 + RANDOM % 20000))
ssh-keygen -q -t ed25519 -N '' -f "$T/host_key" -C e2e-host
ssh-keygen -q -t ed25519 -N '' -f "$T/good_key" -C e2e-good
ssh-keygen -q -t ed25519 -N '' -f "$T/wrong_key" -C e2e-wrong
cp "$T/good_key.pub" "$T/authorized_keys"
cat > "$T/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $T/host_key
PidFile $T/sshd.pid
AuthorizedKeysFile $T/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
EOF
/usr/sbin/sshd -f "$T/sshd_config" -E "$T/sshd.log" || { echo "Could not start a test sshd."; exit 1; }
for _ in $(seq 1 400); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "The test sshd did not start."; cat "$T/sshd.log"; exit 1; }

P=$T/project; S=$T/server; mkdir -p "$P/scripts" "$S"
echo "marker-from-the-server" > "$S/marker.txt"
cat > "$P/scripts/deploy.sh" <<EOS
#!/bin/bash
set -euo pipefail
ssh -o UserKnownHostsFile=$T/known_hosts -o StrictHostKeyChecking=accept-new -p "\$DEPLOY_SSH_PORT" "\$DEPLOY_SSH" "cd '\$DEPLOY_PATH' && echo release-2 > release.txt && cat release.txt"
echo "token=\$API_TOKEN"
EOS
chmod +x "$P/scripts/deploy.sh"
TOKEN='tok_e2e-Canary-31qK'
PW='e2e-Canary-Pass-77'
export VAULT_TEST_HOME=$T/home VAULT_TEST_KNOWN_HOSTS=$T/known_hosts
python3 -I - "$T/seed.json" "$P" "$S" "$PORT" "$(whoami)" "$T/good_key" "$T/wrong_key" "$TOKEN" "$PW" <<'EOS'
import hashlib, json, sys
out, p, s, port, user, good, wrong, token, pw = sys.argv[1:]
t = "2026-01-01T00:00:00Z"
sha = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()
json.dump(dict(version=1,
    secrets=[dict(id="k1", name="API token", env="API_TOKEN", kind="token", value=token, allowedHosts=["127.0.0.1"], updatedAt=t)],
    servers=[
        dict(id="g", name="Good", host="127.0.0.1", port=int(port), user=user, auth="key", secret=open(good).read(), updatedAt=t),
        dict(id="w", name="Wrong", host="127.0.0.1", port=int(port), user=user, auth="key", secret=open(wrong).read(), updatedAt=t),
        dict(id="pw", name="Pass", host="127.0.0.1", port=int(port), user=user, auth="password", secret=pw, updatedAt=t),
    ],
    projects=[dict(id="p1", name="e2e", path=p, secretIDs=["k1"], disabledApps=[],
        links=[dict(id="l1", serverID="g", label="main", path=s, env=dict(target="DEPLOY_SSH", port="DEPLOY_SSH_PORT", path="DEPLOY_PATH"))],
        actions=[dict(name="deploy", script="scripts/deploy.sh", args=[], pins=[dict(path="scripts/deploy.sh", sha256=sha(p + "/scripts/deploy.sh"))])])]),
  open(out, "w"))
EOS
"$V" __seed "$T/seed.json"

echo "login check, real ssh"
out=$("$V" __check-login g); has "the right key logs in" '"ok":true' "$out"
out=$("$V" __check-login w); has "a wrong key is turned down" '"reason":"login"' "$out"
if command -v sshpass >/dev/null || [[ -x /opt/homebrew/bin/sshpass ]]; then
  # A non-root sshd cannot check passwords, so every password is turned down: the real sshpass path, failing.
  out=$("$V" __check-login pw); has "a refused password is named, through the real sshpass" '"reason":"login"' "$out"; hasnt "the password stays out of the message" "$PW" "$out"
else
  echo "  skip  password check: sshpass is not installed"
fi

echo "commands, real ssh"
out=$(cd "$P" && "$V" ssh main -- pwd 2>&1); has "commands start in the mapped folder" "$S" "$out"
out=$(cd "$P" && "$V" ssh main -- cat marker.txt 2>&1); has "reads a file on the server" "marker-from-the-server" "$out"
(cd "$P" && "$V" ssh main -- 'exit 7' >/dev/null 2>&1); code "the remote exit code comes back" 7 $?
out=$(cd "$P" && "$V" run deploy 2>&1); rc=$?
code "the approved deploy succeeds" 0 "$rc"; has "the deploy ran on the server" "release-2" "$out"
[[ "$(cat "$S/release.txt" 2>/dev/null)" == "release-2" ]] && ok "the server folder changed" || bad "the server folder did not change"
has "a token the script prints is redacted" "token=<redacted:API token>" "$out"; hasnt "the token never appears" "$TOKEN" "$out"

after=$(shasum -a 256 ~/.ssh/known_hosts 2>/dev/null | cut -d' ' -f1)
[[ "$before" == "$after" ]] && ok "~/.ssh/known_hosts is untouched" || bad "~/.ssh/known_hosts changed"

echo
echo "passed $pass, failed $fail"
[[ $fail == 0 ]]
