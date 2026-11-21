#!/bin/sh
# Build NotifProbe.app. Runs in CI (desk-probes.yml), not on Penn's Macs.
# SIGN_ID names the signing identity; CI uses "Clamshell Dev" so Full Disk Access and
# Accessibility carry over to the next build. Without it the build is signed ad hoc.
set -eu
cd "$(dirname "$0")"
OUT=${1:-build}
APP="$OUT/NotifProbe.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/NotifProbe" NotifProbe.swift
cp Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_ID:--}" --identifier com.frindle.desk.e7probe "$APP"
codesign --verify --strict --verbose=1 "$APP"
