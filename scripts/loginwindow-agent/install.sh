#!/bin/bash
# Manual, opt-in install of the experimental login-window agent.
# Clamshell never runs this. Run it yourself, with sudo, only after the
# loginwindow-probe has shown capture and input work at the login window:
#
#   sudo /path/to/clamshell/scripts/loginwindow-agent/install.sh
#
# It copies one launchd plist into /Library/LaunchAgents. It does not touch
# Screen Sharing, SSH, FileVault or any other setting: keep Screen Sharing and
# SSH on until the agent has been through real reboots, so there is always
# another way in. Undo with uninstall.sh.
set -euo pipefail

LABEL="com.frindle.clamshell.loginwindow-agent"
SRC="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
DEST="/Library/LaunchAgents/${LABEL}.plist"
APP="/Applications/Clamshell.app/Contents/MacOS/Clamshell"

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
if [ ! -x "$APP" ]; then echo "Clamshell is not installed at /Applications/Clamshell.app." >&2; exit 1; fi
if [ ! -f "$SRC" ]; then echo "Missing $SRC" >&2; exit 1; fi
plutil -lint "$SRC" >/dev/null
if ! "$APP" loginwindow-agent 2>/dev/null | grep -q "nothing to do"; then
    echo "This Clamshell build has no working loginwindow-agent command. Update Clamshell first." >&2
    exit 1
fi

install -o root -g wheel -m 644 "$SRC" "$DEST"
echo "Installed $DEST"
echo "It starts the next time the login window appears (log out or reboot)."
echo "Log: /var/tmp/clamshell-loginwindow-agent.log"
echo "Keep Screen Sharing and SSH on. Remove with uninstall.sh."
