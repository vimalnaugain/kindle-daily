#!/bin/sh
# Name: Daily
# Author: Daily
# Icon: /mnt/us/daily/assets/daily-icon.png
# daily-managed-scriptlet-v1
# Opens Daily, copied over USB into /mnt/us/daily (or installed with KPM).
for LAUNCH in /mnt/us/daily/launch.sh /mnt/us/kmc/kpm/packages/daily/launch.sh; do
    if [ -f "${LAUNCH}" ]; then
        exec /bin/sh "${LAUNCH}" >/dev/null 2>&1
    fi
done
eips 1 36 "Daily: /mnt/us/daily/launch.sh not found. Copy the daily folder again." >/dev/null 2>&1
