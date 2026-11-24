#!/bin/sh
# Name: Daily
# Author: Daily
# Icon: /mnt/us/daily-icon.png
# daily-managed-scriptlet-v1
# Opens the Daily dashboard (installed with KPM). Starts Daily's launch script
# directly rather than via `kpm launch`, so KPM's banner isn't shown.
LAUNCH=/mnt/us/kmc/kpm/packages/daily/launch.sh
if [ -f "${LAUNCH}" ]; then
    exec /bin/sh "${LAUNCH}" >/dev/null 2>&1
fi
exec /var/local/kmc/bin/kpm launch daily
