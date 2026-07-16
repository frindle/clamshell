#!/usr/bin/env bash
# Builds Clamshell.app and Clamshell-<version>.dmg from the SwiftPM binary.
# No Xcode project, no external tools — swift build + hdiutil + codesign.
#
# Usage: ./package.sh [version]   (defaults to version in this script)

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.8.0}"
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

# Prefer a stable local signing identity when one exists: ad-hoc signatures
# change every build, which invalidates TCC grants (Accessibility) on every
# update. Create once in Keychain Access: Certificate Assistant → Create a
# Certificate → name "Clamshell Dev", type "Code Signing".
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Clamshell Dev"; then
    SIGN_ID="Clamshell Dev"
else
    SIGN_ID="-"
fi
echo "=== codesign (identity: ${SIGN_ID}) ==="
# Copied files can carry Finder/quarantine extended attributes, which
# codesign rejects ("resource fork, Finder information, or similar
# detritus not allowed"). Strip them first.
xattr -cr "${APP}"
# No --deep: it's deprecated for signing, and the bundle has no nested code
# (the resource bundle is data-only).
codesign --force --sign "${SIGN_ID}" "${APP}"

echo "=== creating ${DMG} ==="
mkdir -p dist/dmg-root
cp -R "${APP}" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Clamshell" -srcfolder dist/dmg-root -ov -format UDZO "${DMG}" -quiet
rm -rf dist/dmg-root

echo "=== done ==="
ls -lh dist/
