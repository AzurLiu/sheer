#!/bin/zsh
# Build Sheer.app (needs only the Xcode Command Line Tools: `xcode-select --install`).
#
#   ./build.sh          release build → build/Sheer.app and dist/Sheer.zip; signed with Sheer's
#                       certificate when SHEER_SIGNING_P12 / SHEER_SIGNING_PASSWORD are set (the release
#                       workflow sets them), ad-hoc otherwise
#   ./build.sh --dev    development build: includes the self-check tooling and signs with a stable
#                       requirement so macOS keeps your permissions across rebuilds (local use only)
set -euo pipefail
cd "$(dirname "$0")"

DEV=0
[[ "${1:-}" == "--dev" ]] && DEV=1

APP=build/Sheer.app
TMP=build/tmp
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP" dist

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App icon: drawn in code → .iconset → .icns
swiftc -O Icon/make_icon.swift -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

FLAGS=(-O -swift-version 5)
(( DEV )) && FLAGS+=(-D SHEER_DEBUG)
for arch in arm64 x86_64; do
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos11.0" -Xlinker -weak_framework -Xlinker ScreenCaptureKit Sources/*.swift -o "$TMP/Sheer-$arch"
done
lipo -create "$TMP/Sheer-arm64" "$TMP/Sheer-x86_64" -output "$APP/Contents/MacOS/Sheer"
rm -rf "$TMP"

if (( DEV )); then
  # Stable designated requirement: permissions survive rebuilds. Don't ship this — any app claiming
  # the same identifier would satisfy it.
  codesign --force --sign - -r='designated => identifier "io.github.sheer.Sheer"' "$APP"
elif [[ -n "${SHEER_SIGNING_P12:-}" ]]; then
  # Sheer's own certificate (a self-signed one: no developer account needed), passed in by the release
  # workflow from the repository's secrets as a base64 .p12 and its password. Every version signed with
  # it has the same identity, so macOS keeps Sheer's permissions across updates, and the in-app updater
  # only installs a version signed with it. The certificate isn't trusted, so it's used from a throwaway
  # keychain by its hash.
  KC="$PWD/build/signing.keychain-db"; KP=$(uuidgen)
  ORIG=(${(f)"$(security list-keychains -d user | tr -d '"' | sed 's/^ *//')"})
  cleanup() { security list-keychains -d user -s "${ORIG[@]}"; security delete-keychain "$KC" 2>/dev/null; rm -f build/signing.p12; }
  trap cleanup EXIT
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p "$KP" "$KC"
  security set-keychain-settings -lut 3600 "$KC"
  security unlock-keychain -p "$KP" "$KC"
  print -rn -- "$SHEER_SIGNING_P12" | base64 --decode > build/signing.p12
  security import build/signing.p12 -k "$KC" -P "${SHEER_SIGNING_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KP" "$KC" >/dev/null
  security list-keychains -d user -s "$KC" "${ORIG[@]}"
  ID=$(security find-identity -p codesigning "$KC" | awk '/"Sheer Code Signing"/ { print $2; exit }')
  [[ -n "$ID" ]] || { echo "❌ no Sheer Code Signing identity in SHEER_SIGNING_P12"; exit 1; }
  codesign --force --sign "$ID" "$APP"
  codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf' || { echo "❌ not signed with the certificate"; exit 1; }
  rm -f dist/Sheer.zip
  ditto -c -k --keepParent "$APP" dist/Sheer.zip
else
  # Ad-hoc signature with the default (hash-based) requirement.
  codesign --force --sign - "$APP"
  rm -f dist/Sheer.zip
  ditto -c -k --keepParent "$APP" dist/Sheer.zip
fi
codesign --verify --strict "$APP"
echo "✅ built $APP$( (( DEV )) && echo ' (dev)' || echo ' and dist/Sheer.zip')"
