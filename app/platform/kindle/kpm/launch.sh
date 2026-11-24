#!/bin/sh
# KPM launch hook (`kpm launch daily`), used by the library item and KUAL.
# Runs Daily detached, so the launcher that started us can return at once.
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DAILY_HOME="${DAILY_HOME:-${KINDLE_ROOT:-/mnt/us}/daily}"
mkdir -p "${DAILY_HOME}"
cd "${SELF_DIR}" || exit 1
nohup /bin/sh "${SELF_DIR}/daily.sh" "$@" >> "${DAILY_HOME}/crash.log" 2>&1 &
