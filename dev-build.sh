#!/usr/bin/env bash
# Debug build that keeps a STABLE code signature across rebuilds.
#
# Raw `swift build` produces an ad-hoc (or unsigned) binary whose signature
# changes every build. macOS TCC keys Accessibility/Screen-Recording grants on
# the signature, so each rebuild looks like a brand-new app and the grant is
# dropped — you get re-prompted on every launch. Signing the debug binary with
# the stable "Clamshell Dev" identity (same one package.sh uses) gives it a
# constant designated requirement, so the grant survives rebuilds.
#
# Create the identity once: Keychain Access → Certificate Assistant →
# Create a Certificate → name "Clamshell Dev", type "Code Signing".
#
# Usage: ./dev-build.sh [extra swift build args]
set -euo pipefail
cd "$(dirname "$0")"

swift build "$@"
BIN=".build/debug/Clamshell"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Clamshell Dev"; then
    xattr -cr "$BIN"
    codesign --force --sign "Clamshell Dev" "$BIN"
    echo "signed $BIN with 'Clamshell Dev' — TCC grants persist across rebuilds"
else
    echo "no 'Clamshell Dev' identity found — $BIN left ad-hoc"
    echo "(TCC will re-prompt each rebuild; see README build-from-source to set one up)"
fi
