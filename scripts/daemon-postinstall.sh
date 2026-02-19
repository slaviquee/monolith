#!/bin/bash
set -euo pipefail

LABEL="com.monolith.daemon"
PLIST="/Library/LaunchAgents/com.monolith.daemon.plist"

# Start/refresh agent for currently logged-in GUI user (if any).
CONSOLE_USER=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && $3 != "loginwindow" { print $3 }')
if [ -n "${CONSOLE_USER:-}" ] && id "$CONSOLE_USER" >/dev/null 2>&1; then
  CONSOLE_UID=$(id -u "$CONSOLE_USER")
  /bin/launchctl bootout "gui/$CONSOLE_UID/$LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/$CONSOLE_UID" "$PLIST" >/dev/null 2>&1 || true
  /bin/launchctl enable "gui/$CONSOLE_UID/$LABEL" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/$CONSOLE_UID/$LABEL" >/dev/null 2>&1 || true
fi

exit 0
