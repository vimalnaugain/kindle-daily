#!/bin/sh
# KPM uninstall hook: remove what install.sh added. Settings, API keys and
# cached news in /mnt/us/daily are kept; delete that folder to remove them.
ROOT="${KINDLE_ROOT:-/mnt/us}"
SCRIPTLET="${ROOT}/documents/Daily.sh"
if [ -f "${SCRIPTLET}" ] && grep -q '^# daily-managed-scriptlet-v1$' "${SCRIPTLET}"; then
    rm -f "${SCRIPTLET}"
fi
rm -f "${ROOT}/daily-icon.png"
if [ -f "${ROOT}/extensions/daily/menu.json" ] && grep -q 'daily.*/launch.sh' "${ROOT}/extensions/daily/menu.json"; then
    rm -rf "${ROOT}/extensions/daily"
fi
echo "Daily removed. Your settings are still in ${ROOT}/daily."
