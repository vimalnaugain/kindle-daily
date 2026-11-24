#!/bin/sh
# Name: Install Daily
# Author: Daily
# daily-installer-scriptlet-v1
# Installs (or updates) Daily from the daily-install folder that the USB zip
# put on the Kindle. No terminal or KPM needed: tap this item in the library.
ROOT="${KINDLE_ROOT:-/mnt/us}"
SRC="${ROOT}/daily-install"
DEST="${ROOT}/daily-app"
say() { eips 1 36 "$1                                        " >/dev/null 2>&1; return 0; }

if [ ! -f "${SRC}/daily-luajit" ]; then
    say "Daily: install files not found in ${SRC}"
    exit 1
fi
say "Installing Daily..."
rm -rf "${DEST}.new" && cp -r "${SRC}" "${DEST}.new" || { say "Daily: copy failed"; exit 1; }
rm -rf "${DEST}" && mv "${DEST}.new" "${DEST}"
chmod 755 "${DEST}/daily-luajit" "${DEST}"/*.sh
if (cd "${DEST}" && KINDLE_ROOT="${ROOT}" sh ./install.sh > "${ROOT}/daily-install.log" 2>&1); then
    rm -rf "${SRC}"
    rm -f "${ROOT}/documents/install-daily.sh"
    say "Daily installed. Open 'Daily' from your library."
else
    say "Daily: install failed, see daily-install.log"
    exit 1
fi
