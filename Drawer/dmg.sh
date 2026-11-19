#!/bin/zsh
# Packs build/Drawer.app (run build.sh first) into build/release/Drawer-<version>.dmg: a window with Drawer and an
# Applications shortcut to drag it onto. Lays the window out through Finder, so the first run asks to let your terminal
# control Finder; without that, the DMG still works, just without the arranged window.
set -e
cd "$(dirname "$0")"
APP=build/Drawer.app
[[ -d "$APP" ]] || { echo "No $APP: run build.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VERSION" == *.*.* ]] || VERSION="$VERSION.0"
OUT=build/release/Drawer-$VERSION.dmg
VOL="Drawer $VERSION"
TMP=$(mktemp -d)
MNT=""
trap '[[ -n "$MNT" ]] && hdiutil detach "$MNT" -quiet 2>/dev/null; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stage/.background" build/release
cp -R "$APP" "$TMP/stage/"
ln -s /Applications "$TMP/stage/Applications"
swift DMGBackground.swift "$TMP/bg.png" 1
swift DMGBackground.swift "$TMP/bg@2x.png" 2
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$TMP/stage/.background/background.tiff" 2>/dev/null

hdiutil create -quiet -srcfolder "$TMP/stage" -volname "$VOL" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg"
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP/rw.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}')
VOL=$(basename "$MNT")   # "Drawer 0.4.1", or "Drawer 0.4.1 1" if one by that name is already mounted

osascript <<APPLESCRIPT || echo "Couldn't arrange the window through Finder; the DMG works without it."
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 740, 528}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Drawer.app" of container window to {140, 180}
    set position of item "Applications" of container window to {400, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach -quiet "$MNT"
MNT=""
rm -f "$OUT"
hdiutil convert -quiet "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
hdiutil verify -quiet "$OUT"
echo "Built $OUT"
shasum -a 256 "$OUT"
