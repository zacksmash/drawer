#!/bin/zsh
# Renders the guide's screenshots (docs/peeks-*.png, docs/switcher-*.png) from Drawer's own peek and switcher views,
# drawn offscreen over mock windows. Nothing is launched and no permission is needed.
set -e
cd "$(dirname "$0")"
SRC=../../Drawer
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O $SRC/Config.swift $SRC/Drawer.swift $SRC/Carousel.swift $SRC/Switcher.swift $SRC/Peeks.swift $SRC/Hotkey.swift \
  $SRC/Settings.swift main.swift -o "$TMP/screenshots"
"$TMP/screenshots" "$(cd .. && pwd)"
