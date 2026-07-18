#!/usr/bin/env bash
# Builds Clamshell.app and Clamshell-<version>.dmg from the SwiftPM binary.
# No Xcode project, no external tools — swift build + hdiutil + codesign.
#
# Usage: ./package.sh [version]   (defaults to version in this script)

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.9.0}"
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
if [ -n "${SIGN_ID:-}" ]; then
    :   # explicit override — CI passes the identity directly, because a
        # freshly imported (untrusted) cert isn't listed by `find-identity -v`
        # even though codesign can still sign with it.
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Clamshell Dev"; then
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

echo "=== creating ${DMG} (drag-to-Applications layout) ==="
VOL="Clamshell"
mkdir -p dist/dmg-root
cp -R "${APP}" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
# Build a read-write image first so Finder can persist a window layout
# (.DS_Store: icon positions, view options), then convert to compressed
# read-only for distribution. Standard hdiutil + osascript recipe.
RW="dist/rw.dmg"
hdiutil create -volname "${VOL}" -srcfolder dist/dmg-root -ov -format UDRW "${RW}" -quiet
# No -nobrowse: Finder needs the volume mounted normally to script its window.
hdiutil attach "${RW}" -noautoopen -quiet
sleep 2   # give Finder a moment to register the volume
osascript <<EOF || echo "warning: Finder layout step failed — DMG still valid, just no custom window"
tell application "Finder"
  tell disk "${VOL}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 720, 460}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "Clamshell.app" of container window to {140, 170}
    set position of item "Applications" of container window to {380, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
# Finder writes com.apple.FinderInfo onto the app bundle while laying out the
# window, which trips `codesign --verify --strict` ("resource fork ... not
# allowed") — and that same verify runs in the self-updater. Strip and re-sign
# the copy that actually ships in the DMG. Icon positions live in the
# container's .DS_Store, so this doesn't disturb the layout.
xattr -cr "/Volumes/${VOL}/Clamshell.app"
codesign --force --sign "${SIGN_ID}" "/Volumes/${VOL}/Clamshell.app"
sync
hdiutil detach "/Volumes/${VOL}" -quiet
hdiutil convert "${RW}" -format UDZO -o "${DMG}" -ov -quiet
rm -f "${RW}"
rm -rf dist/dmg-root

echo "=== done ==="
ls -lh dist/
