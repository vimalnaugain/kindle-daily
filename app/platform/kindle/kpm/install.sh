#!/bin/sh
# KPM install hook. KPM has unpacked Daily into its package folder
# (/mnt/us/kmc/kpm/packages/daily) and runs this from there.
#   - adds a "Daily" item to the Kindle library (a scriptlet) to launch it
#   - adds a KUAL menu entry too, if KUAL is installed
#   - creates /mnt/us/daily for settings and cached news (kept on upgrade)
set -eu
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="${KINDLE_ROOT:-/mnt/us}"
HOME_DIR="${ROOT}/daily"

if [ ! -d "${ROOT}/documents" ]; then
    echo "The Kindle documents folder is not available" >&2
    exit 1
fi

chmod 755 "${SELF_DIR}/daily-luajit" "${SELF_DIR}/daily.sh" "${SELF_DIR}/launch.sh" "${SELF_DIR}/uninstall.sh"

mkdir -p "${HOME_DIR}"
cp -f "${SELF_DIR}/config.example.lua" "${HOME_DIR}/config.example.lua"
if [ ! -f "${HOME_DIR}/config.lua" ]; then
    cp "${SELF_DIR}/config.example.lua" "${HOME_DIR}/config.lua"
    echo "Created ${HOME_DIR}/config.lua (city, news address)."
fi

cp -f "${SELF_DIR}/assets/daily-icon.png" "${ROOT}/daily-icon.png"
# The library item and KUAL entry point at wherever this copy lives: KPM's
# package folder, or /mnt/us/daily-app for the USB installer.
KPM_DIR=/mnt/us/kmc/kpm/packages/daily
sed "s#${KPM_DIR}#${SELF_DIR}#g" "${SELF_DIR}/scriptlet/daily.sh" > "${ROOT}/documents/Daily.sh"
chmod 755 "${ROOT}/documents/Daily.sh"

if [ -d "${ROOT}/extensions" ]; then
    mkdir -p "${ROOT}/extensions/daily"
    cp -f "${SELF_DIR}/kual/config.xml" "${ROOT}/extensions/daily/"
    sed "s#${KPM_DIR}#${SELF_DIR}#g" "${SELF_DIR}/kual/menu.json" > "${ROOT}/extensions/daily/menu.json"
fi

if [ "${1:-}" = "upgrade" ]; then
    echo "Daily upgraded. Your settings are unchanged."
else
    echo "Daily installed. Open 'Daily' from your Kindle library."
fi
