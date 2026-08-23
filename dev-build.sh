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

# Always carry the smartcard entitlement: CryptoTokenKit hides every smart
# card from an unentitled process, so without it "Test YubiKey Confirmation…"
# can only ever report "TKSmartCardSlotManager unavailable". The entitlement
# is independent of the identity, so this costs the ad-hoc case nothing.
ENTITLEMENTS="scripts/smartcard.entitlements"

xattr -cr "$BIN"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Clamshell Dev"; then
    codesign --force --sign "Clamshell Dev" --entitlements "$ENTITLEMENTS" "$BIN"
    echo "signed $BIN with 'Clamshell Dev' + smartcard entitlement — TCC grants persist across rebuilds"
else
    # Ad-hoc, but still entitled — the YubiKey path works, TCC just re-prompts.
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN"
    echo "no 'Clamshell Dev' identity found — $BIN ad-hoc signed with the smartcard entitlement"
    echo "(TCC will re-prompt each rebuild; see README build-from-source to set one up)"
fi

# `swift run` re-links and drops the signature — invoke the signed binary
# directly (./.build/debug/Clamshell) for anything touching a YubiKey.
