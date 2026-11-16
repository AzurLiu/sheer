#!/bin/zsh
# Regenerates Packaging/dmg/DS_Store: the Finder layout of the Sheer.dmg window (window size, icon size and
# positions, no toolbar, the arrow from arrow.swift as background picture). Run it on a Mac, after a release
# build, whenever the layout should change. Finder itself writes the file, so it is in the exact form Finder
# reads back (other tools' versions come out without the picture on recent macOS). build.sh copies it into
# every Sheer.dmg. The arrow's background is transparent, so the window keeps the system's light or dark colour.
#
#   ./build.sh && Packaging/dmg/make_template.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -d build/Sheer.app ]] || { echo "build first: ./build.sh"; exit 1; }
[[ -e /Volumes/Sheer ]] && { echo "eject the volume named Sheer first"; exit 1; }

TMP=$(mktemp -d)
trap 'hdiutil detach /Volumes/Sheer -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT
swiftc -O Packaging/dmg/arrow.swift -o "$TMP/arrow"
"$TMP/arrow" "$TMP/arrow.png" 1
"$TMP/arrow" "$TMP/arrow@2x.png" 2
hdiutil create -quiet -size 20m -fs HFS+ -volname Sheer -ov "$TMP/rw.dmg"
hdiutil attach -quiet -nobrowse -noautoopen "$TMP/rw.dmg"
mkdir /Volumes/Sheer/.background
tiffutil -cathidpicheck "$TMP/arrow.png" "$TMP/arrow@2x.png" -out /Volumes/Sheer/.background/arrow.tiff >/dev/null 2>&1
ditto build/Sheer.app /Volumes/Sheer/Sheer.app
ln -s /Applications /Volumes/Sheer/Applications

# A 520×300 pt window (plus the title bar), 128 pt icons side by side.
osascript <<'EOF'
tell application "Finder"
  tell disk "Sheer"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 720, 468}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set text size of vo to 13
    set shows icon preview of vo to false
    set background picture of vo to file ".background:arrow.tiff"
    set position of item "Sheer.app" of container window to {140, 140}
    set position of item "Applications" of container window to {380, 140}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sleep 2
cp /Volumes/Sheer/.DS_Store Packaging/dmg/DS_Store
echo "✅ wrote Packaging/dmg/DS_Store"
