#!/bin/sh
# Daily launcher for jailbroken Kindles (FW 5.x). Started from the library
# item (KPM install) or KUAL. Pauses the Kindle UI, runs Daily, restores the UI.
#
#   daily.sh                    pause the status bar / window manager only
#   daily.sh --framework_stop   stop the whole Kindle framework (more RAM, slower exit)
#
# Updates: any daily*.kpkg found in $DAILY_HOME/update (copied over USB, or
# downloaded by Settings > Check for updates) is installed before Daily starts.
# Daily exits with code 85 to ask for "apply update and restart".

# Run from a copy in /tmp, so an update can replace this file safely.
if [ -z "${DAILY_RUNNING_COPY}" ]; then
    DAILY_DIR="$(cd "$(dirname "$0")" && pwd)"
    export DAILY_DIR
    export DAILY_RUNNING_COPY=1
    cp "$0" /tmp/daily-launcher.sh && exec /bin/sh /tmp/daily-launcher.sh "$@"
fi

# Settings and cached news. Defaults to the app folder (USB install);
# the KPM package sets DAILY_HOME=/mnt/us/daily so upgrades never touch it.
DAILY_HOME="${DAILY_HOME:-${DAILY_DIR}}"
UPDATE_DIR="${DAILY_HOME}/update"
mkdir -p "${DAILY_HOME}" "${UPDATE_DIR}"
LOG="${DAILY_HOME}/crash.log"
STOP_FRAMEWORK="no"
[ "$1" = "--framework_stop" ] && STOP_FRAMEWORK="yes"

log() { echo "$(date '+%H:%M:%S') daily.sh: $*" >> "${LOG}"; }
say() { eips 1 38 "$1                                   " >/dev/null 2>&1; }

# Install the newest update package in UPDATE_DIR, if any. Settings, keys
# and cached news live elsewhere and are not touched.
apply_update() {
    for PKG in $(ls -t "${UPDATE_DIR}"/daily*.kpkg 2>/dev/null); do
        if install_package "${PKG}"; then
            rm -f "${UPDATE_DIR}"/daily*.kpkg
            return 0
        fi
    done
    return 1
}

install_package() {
    PKG="$1"
    log "applying update ${PKG}"
    say "Updating Daily..."
    WORK="/tmp/daily-update.$$"
    rm -rf "${WORK}" && mkdir -p "${WORK}"
    if tar -xzf "${PKG}" -C "${WORK}" 2>>"${LOG}" \
        && grep -q '"id": *"daily"' "${WORK}/manifest.json" 2>/dev/null \
        && [ -f "${WORK}/daily-luajit" ] && [ -f "${WORK}/main.lua" ]; then
        cp -rf "${WORK}/." "${DAILY_DIR}/" \
            && chmod 755 "${DAILY_DIR}/daily-luajit" "${DAILY_DIR}"/*.sh 2>/dev/null
        # KPM install: refresh the library item, icon and KUAL entry too
        case "${DAILY_DIR}" in
            */kmc/kpm/packages/*) (cd "${DAILY_DIR}" && sh ./install.sh upgrade >> "${LOG}" 2>&1) ;;
        esac
        VERSION="$(tr -d '\n' < "${WORK}/VERSION" 2>/dev/null)"
        log "updated to ${VERSION}"
        say "Daily updated to ${VERSION}"
        rm -rf "${WORK}"
        return 0
    fi
    log "update package ${PKG} is not valid; moved aside"
    say "Update failed: not a Daily package"
    mv -f "${PKG}" "${PKG}.invalid"
    rm -rf "${WORK}"
    return 1
}

apply_update

# Upstart (most FW 5.x devices) or SysV (Kindle Touch / early FW)?
if [ -e /sbin/initctl ] || [ -e /etc/upstart ]; then INIT=upstart; else INIT=sysv; fi

AWESOME_STOPPED=no
PILLOW_DISABLED=no
if [ "${STOP_FRAMEWORK}" = "yes" ]; then
    log "stopping framework"
    if [ "${INIT}" = "upstart" ]; then
        trap "" TERM            # stopping lab126_gui also signals KUAL's children
        stop lab126_gui
        usleep 1250000
        trap - TERM
    else
        /etc/init.d/framework stop
    fi
else
    if [ "${INIT}" = "upstart" ]; then
        # Hide the status bar and freeze the window manager so the clock
        # doesn't draw over our pages.
        lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null && PILLOW_DISABLED=yes
        if killall -STOP awesome 2>/dev/null; then AWESOME_STOPPED=yes; fi
        # Daily lets the window manager run while asleep on Kindles with ads
        export AWESOME_STOPPED
    else
        killall -STOP cvm 2>/dev/null
    fi
fi

# Keep the device from mounting USB storage under us.
killall -STOP volumd 2>/dev/null && VOLUMD_STOPPED=yes

while true; do
    cd "${DAILY_DIR}" || exit 1
    log "starting"
    ./daily-luajit main.lua --kindle --home "${DAILY_HOME}" >> "${LOG}" 2>&1
    RC=$?
    log "exited with ${RC}"
    # 85: Daily downloaded an update and asked to restart into it
    [ "${RC}" = "85" ] && apply_update && continue
    break
done

[ "${VOLUMD_STOPPED}" = "yes" ] && killall -CONT volumd 2>/dev/null

if [ "${STOP_FRAMEWORK}" = "yes" ]; then
    log "restarting framework"
    if [ "${INIT}" = "upstart" ]; then cd / && start lab126_gui; else cd / && /etc/init.d/framework start; fi
else
    if [ "${INIT}" = "upstart" ]; then
        [ "${AWESOME_STOPPED}" = "yes" ] && killall -CONT awesome 2>/dev/null
        if [ "${PILLOW_DISABLED}" = "yes" ]; then
            lipc-set-prop com.lab126.pillow disableEnablePillow enable
        fi
        # Bring the home screen back and repaint it.
        lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
    else
        killall -CONT cvm 2>/dev/null
        eips -c
    fi
fi
exit ${RC}
