#!/bin/zsh
# Runs Sheer's tests (Tests/main.swift), built together with the app's sources. 运行测试
#   ./test.sh
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/tests
mkdir -p "$OUT"
rm -f "$OUT/run"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  $(ls Sources/*.swift | grep -v '/main.swift$') Tests/main.swift -o "$OUT/run" 2>&1 | grep -E " error:" || true
[[ -x "$OUT/run" ]] || { echo "❌ tests didn't build"; exit 1; }
# A fixed time zone: the Dynamic-wallpaper cases were seen on a Mac set to America/Regina.
TZ=America/Regina "$OUT/run"
