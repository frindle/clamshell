#!/usr/bin/env bash
# Builds Clamshell.app and Clamshell-<version>.dmg from the SwiftPM binary.
# No Xcode project, no external tools — swift build + hdiutil + codesign.
#
# Usage: ./package.sh [version]   (defaults to version in this script)

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.4.1}"
APP="dist/Clamshell.app"
DMG="dist/Clamshell-${VERSION}.dmg"

echo "=== building release binary (universal) ==="
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/Clamshell"

echo "=== assembling ${APP} ==="
rm -rf dist
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Clamshell"
# SwiftPM resource bundle (noVNC assets) — Bundle.module finds it in
# Contents/Resources when running from the .app.
cp -R ".build/apple/Products/Release/Clamshell_Clamshell.bundle" "${APP}/Contents/Resources/"
cp AppIcon.icns "${APP}/Contents/Resources/"

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Clamshell</string>
    <key>CFBundleDisplayName</key><string>Clamshell</string>
    <key>CFBundleIdentifier</key><string>com.frindle.clamshell</string>
    <key>CFBundleExecutable</key><string>Clamshell</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

echo "=== ad-hoc codesign ==="
codesign --force --deep --sign - "${APP}"

echo "=== creating ${DMG} ==="
mkdir -p dist/dmg-root
cp -R "${APP}" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Clamshell" -srcfolder dist/dmg-root -ov -format UDZO "${DMG}" -quiet
rm -rf dist/dmg-root

echo "=== done ==="
ls -lh dist/
