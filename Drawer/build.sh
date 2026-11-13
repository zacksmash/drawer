#!/bin/zsh
# Builds build/Drawer.app. Pass --install to copy it to /Applications and relaunch it.
set -e
cd "$(dirname "$0")"
APP=build/Drawer.app
rm -rf "$APP" build/Drawer.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/Drawer.iconset

swiftc -O Config.swift Drawer.swift Hotkey.swift Settings.swift main.swift -o "$APP/Contents/MacOS/Drawer"

# Icon
swift Icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/Drawer.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/Drawer.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/Drawer.iconset -o "$APP/Contents/Resources/Drawer.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.drawer</string>
  <key>CFBundleName</key><string>Drawer</string>
  <key>CFBundleExecutable</key><string>Drawer</string>
  <key>CFBundleIconFile</key><string>Drawer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
  pkill -x Drawer || true
  rm -rf /Applications/Drawer.app
  cp -R "$APP" /Applications/
  open /Applications/Drawer.app
  echo "Installed and launched /Applications/Drawer.app"
fi
