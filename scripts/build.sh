#!/bin/bash
# Builds VaultDoor.app. Pass --test for the test binary (see tests/run.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=release
[[ "${1:-}" == "--test" ]] && MODE=test
[[ "${1:-}" == "--keychain-test" ]] && MODE=keychain

OUT=${VAULT_BUILD_DIR:-build}
mkdir -p "$OUT"

# The page is compiled into the binary, so changing it changes the signature.
{
  printf 'let embeddedDashboardBase64 = "'
  base64 < web/dashboard.html | tr -d '\n'
  printf '"\n'
} > "$OUT/Generated.swift"

FLAGS=(-swift-version 5 -target "$(uname -m)-apple-macos13"
  -framework AppKit -framework WebKit -framework LocalAuthentication -framework Security)

case "$MODE" in
  test)
    swiftc -Onone "${FLAGS[@]}" -D VAULT_TEST Sources/*.swift "$OUT/Generated.swift" -o "$OUT/vaultdoor-test"
    echo "$OUT/vaultdoor-test"
    exit 0
    ;;
  keychain)
    swiftc -Onone "${FLAGS[@]}" -D VAULT_TEST -D VAULT_KEYCHAIN_TEST Sources/*.swift "$OUT/Generated.swift" -o "$OUT/vaultdoor-keychain-test"
    codesign --force -s - -o runtime "$OUT/vaultdoor-keychain-test"
    echo "$OUT/vaultdoor-keychain-test"
    exit 0
    ;;
esac

APP="$OUT/VaultDoor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O "${FLAGS[@]}" Sources/*.swift "$OUT/Generated.swift" -o "$APP/Contents/MacOS/vaultdoor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>vaultdoor</string>
  <key>CFBundleIdentifier</key><string>local.vaultdoor.app</string>
  <key>CFBundleName</key><string>VaultDoor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Hardened runtime blocks debuggers and injected libraries, so another process
# running as this user cannot pull the key out of the app's memory.
codesign --force --deep -s - -o runtime --identifier local.vaultdoor.app "$APP"
codesign --verify --deep "$APP"
echo "$APP"
