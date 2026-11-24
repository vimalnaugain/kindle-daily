#!/bin/sh
# USB install without a terminal: build/daily-kindle.zip. Unzipped at the
# root of the Kindle drive it gives:
#   daily-install/                the app (same files as the KPM package)
#   documents/install-daily.sh    "Install Daily" item in the library: tap it once
# The installer moves the app to /mnt/us/daily-app and adds the "Daily"
# library item (and a KUAL entry if KUAL is installed).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${ROOT}/build/kpm/stage"
[ -x "${STAGE}/daily-luajit" ] || { echo "missing ${STAGE}; run tools/package_kpm.sh first" >&2; exit 1; }
OUT="${ROOT}/build/usb"
rm -rf "${OUT}" && mkdir -p "${OUT}/documents"
cp -r "${STAGE}" "${OUT}/daily-install"
cp "${ROOT}/platform/kindle/usb/install-daily.sh" "${OUT}/documents/install-daily.sh"
chmod 755 "${OUT}/documents/install-daily.sh" "${OUT}/daily-install/daily-luajit" "${OUT}/daily-install/"*.sh
rm -f "${ROOT}/build/daily-kindle.zip"
(cd "${OUT}" && zip -qr ../daily-kindle.zip daily-install documents)
echo "wrote ${ROOT}/build/daily-kindle.zip"
