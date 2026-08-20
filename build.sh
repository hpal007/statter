#!/bin/bash
# Builds Statter.app — a double-clickable menu bar app bundle.
#   ./build.sh            build ./Statter.app
#   ./build.sh --install  build, then copy into /Applications and launch it
set -euo pipefail

cd "$(dirname "$0")"

APP="Statter.app"
BUNDLE_ID="com.hpal007.statter"
VERSION="1.0"

echo "==> Compiling"
swiftc -O -parse-as-library \
    -framework SwiftUI -framework AppKit -framework IOKit \
    -o statter StatterApp.swift

if [[ ! -f Statter.icns ]]; then
    echo "==> Drawing icon"
    swift make-icon.swift
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp statter "$APP/Contents/MacOS/Statter"
cp Statter.icns "$APP/Contents/Resources/Statter.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Statter</string>
    <key>CFBundleDisplayName</key>     <string>Statter</string>
    <key>CFBundleExecutable</key>      <string>Statter</string>
    <key>CFBundleIconFile</key>        <string>Statter</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Menu bar accessory: no Dock icon, no main window. -->
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without one, macOS treats the bundle as a new app on every
# rebuild and re-asks for any permissions it has been granted.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    pkill -x Statter 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" "/Applications/$APP"
    open "/Applications/$APP"
    echo "==> Running from /Applications/$APP"
fi
