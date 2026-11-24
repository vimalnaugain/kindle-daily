#!/bin/sh
# Assemble the Kindle install tree and zip it:
#   daily/       -> copy to /mnt/us/daily
#   extensions/  -> copy to /mnt/us/extensions (KUAL menu entry)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/package"
BIN="${ROOT}/build/kindle/daily"
[ -x "${BIN}" ] || { echo "missing ${BIN}; run tools/build_kindle.sh first" >&2; exit 1; }

rm -rf "${OUT}"
mkdir -p "${OUT}/daily" "${OUT}/extensions"
cp "${BIN}" "${OUT}/daily/daily-luajit"
cp "${ROOT}/main.lua" "${ROOT}/platform/kindle/daily.sh" "${OUT}/daily/"
cp -r "${ROOT}/core" "${ROOT}/daily" "${ROOT}/fonts" "${OUT}/daily/"
cp "${ROOT}/LICENSE.tome" "${OUT}/daily/"
[ -f "${ROOT}/VERSION" ] && cp "${ROOT}/VERSION" "${OUT}/daily/"
cp "${ROOT}/config.example.lua" "${OUT}/daily/config.example.lua"
cp -r "${ROOT}/platform/kindle/extensions/daily" "${OUT}/extensions/"
chmod +x "${OUT}/daily/daily-luajit" "${OUT}/daily/daily.sh"
(cd "${OUT}" && zip -qr ../daily-kindle.zip daily extensions)
echo "wrote ${ROOT}/build/daily-kindle.zip"
