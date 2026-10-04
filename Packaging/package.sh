#!/bin/sh
# Builds dist/Nylon.dmg: Nylon.app next to an Applications shortcut to drag it onto.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)

stage=dist/dmg # what the DMG shows: the app and a shortcut to Applications
app=$stage/Nylon.app
rm -rf dist
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/NylonApp" "$app/Contents/MacOS/"
cp -R "$bin/Nylon_NylonApp.bundle" "$app/Contents/Resources/" # the menu bar icons
cp Packaging/Info.plist "$app/Contents/"

# AppIcon.icns from AppIcon.svg (a copy of nylon's docs/assets/logo_neutral.svg): each size macOS asks for,
# drawn at 80% so it has the margin other app icons have
iconset=dist/AppIcon.iconset
mkdir "$iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((size * scale))
        png=$iconset/icon_${size}x${size}$([ $scale = 2 ] && echo @2x || true).png
        sips -s format png -z $((px * 8 / 10)) $((px * 8 / 10)) Packaging/AppIcon.svg --out "$png" >/dev/null
        sips -p $px $px "$png" >/dev/null
    done
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

# Ad hoc signature: the app isn't notarized, so its first launch needs "Open Anyway" in System Settings.
codesign --force --sign - "$app"

ln -s /Applications "$stage/Applications"
hdiutil create -volname Nylon -srcfolder "$stage" -format UDZO dist/Nylon.dmg
rm -r "$stage" "$iconset"
