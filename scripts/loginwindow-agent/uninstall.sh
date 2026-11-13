#!/bin/bash
# Removes the login-window agent installed by install.sh.
#   sudo /path/to/clamshell/scripts/loginwindow-agent/uninstall.sh
set -euo pipefail

LABEL="com.frindle.clamshell.loginwindow-agent"
DEST="/Library/LaunchAgents/${LABEL}.plist"

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
# Stop it if it is loaded in the login-window session (it isn't while a user
# is logged in); a failure here just means it wasn't running.
launchctl bootout "loginwindow/${LABEL}" 2>/dev/null || true
rm -f "$DEST"
echo "Removed $DEST"
