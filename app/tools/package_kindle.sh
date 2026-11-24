#!/bin/sh
# The easy install: build/daily-kindle.zip. Its contents go on the Kindle drive:
#   daily/               the app; settings and cached news also live here
#   documents/Daily.sh   the "Daily" item in the Kindle library (and search)
#   extensions/daily/    a KUAL menu entry, for Kindles that have KUAL
# Then open Daily from the library (or type "Daily" in the search bar).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${ROOT}/build/kpm/stage"
[ -x "${STAGE}/daily-luajit" ] || { echo "missing ${STAGE}; run tools/package_kpm.sh first" >&2; exit 1; }
OUT="${ROOT}/build/usb"
rm -rf "${OUT}" && mkdir -p "${OUT}/documents" "${OUT}/extensions/daily"
cp -r "${STAGE}" "${OUT}/daily"
cp "${ROOT}/platform/kindle/usb/Daily.sh" "${OUT}/documents/Daily.sh"
cp "${ROOT}/platform/kindle/kpm/kual/config.xml" "${OUT}/extensions/daily/"
sed "s#/mnt/us/kmc/kpm/packages/daily#/mnt/us/daily#g" "${ROOT}/platform/kindle/kpm/kual/menu.json" > "${OUT}/extensions/daily/menu.json"
chmod 755 "${OUT}/documents/Daily.sh" "${OUT}/daily/daily-luajit" "${OUT}/daily/"*.sh
rm -f "${ROOT}/build/daily-kindle.zip"
(cd "${OUT}" && zip -qr ../daily-kindle.zip daily documents extensions)
echo "wrote ${ROOT}/build/daily-kindle.zip"
