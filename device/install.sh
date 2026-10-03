#!/bin/sh
# ============================================================================
#  Installer -- run this ON THE KINDLE, as root.
#
#     sh /mnt/us/dashboard/install.sh              install + start
#     sh /mnt/us/dashboard/install.sh --no-start   install only
#     sh /mnt/us/dashboard/install.sh --autostart  also start on every boot
#     sh /mnt/us/dashboard/install.sh --no-autostart  remove boot autostart
#
#  Nothing in here touches your stock screensaver images or any file outside
#  /mnt/us/dashboard, /mnt/us/extensions/dashboard and (optionally)
#  /etc/upstart/dashboard.conf. That is what makes revert trivial.
# ============================================================================

set -u

DASH_DIR=$(dirname "$0")
[ -r "$DASH_DIR/config.sh" ] || DASH_DIR=/mnt/us/dashboard
. "$DASH_DIR/config.sh"
. "$DASH_DIR/lib/util.sh"

EXT_DIR="/mnt/us/extensions/dashboard"
UPSTART_JOB="/etc/upstart/dashboard.conf"

DO_START=1
DO_AUTOSTART=""
for a in "$@"; do
    case "$a" in
        --no-start)     DO_START=0 ;;
        --start)        DO_START=1 ;;
        --autostart)    DO_AUTOSTART=1 ;;
        --no-autostart) DO_AUTOSTART=0 ;;
        *) echo "unknown option: $a"; exit 2 ;;
    esac
done

echo "== Kindle Lockscreen Dashboard installer =="

# --- 0. sanity -------------------------------------------------------------
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "!! must run as root (use KUAL -> Dashboard -> Install, or KOReader's Terminal)"
    exit 1
fi
if [ ! -d /mnt/us/extensions ]; then
    echo "!! /mnt/us/extensions is missing -- is KUAL installed?"
    exit 1
fi

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null

# --- 1. record what we are about to change ---------------------------------
# Captured before anything is modified so uninstall.sh can put it back exactly.
if [ -n "${STATE_DIR:-}" ]; then
    save_power_originals
else
    echo "!! config.sh did not load (STATE_DIR unset)"
    exit 1
fi

# --- 2. checks -------------------------------------------------------------
if [ -r "$DASH_DIR/dashboard.sh" ]; then
    sh "$DASH_DIR/dashboard.sh" probe
else
    echo "!! dashboard.sh not found in $DASH_DIR"
    exit 1
fi

# --- 3. KUAL extension -----------------------------------------------------
if [ -d "$DASH_DIR/kual" ]; then
    echo "-- installing KUAL extension to $EXT_DIR"
    rm -rf "$EXT_DIR" 2>/dev/null
    mkdir -p "$EXT_DIR" 2>/dev/null
    cp -r "$DASH_DIR/kual/." "$EXT_DIR/" 2>/dev/null
    chmod 0755 "$EXT_DIR"/bin/*.sh 2>/dev/null
    if [ -r "$EXT_DIR/menu.json" ]; then
        echo "   ok"
    else
        echo "   !! copy failed"
    fi
else
    echo "-- no kual/ directory next to install.sh, skipping extension"
fi

# --- 4. optional boot autostart -------------------------------------------
if [ "$DO_AUTOSTART" = "1" ] || [ "$DO_AUTOSTART" = "0" ]; then
    echo "-- updating boot autostart"
    if mntroot rw 2>/dev/null; then
        if [ "$DO_AUTOSTART" = "1" ]; then
            cat > "$UPSTART_JOB" <<'EOF'
# Kindle Lockscreen Dashboard
description "Kindle lockscreen weather/clock dashboard"
start on (started framework or started lab126_gui or started system-services)
stop on stopping framework
respawn
respawn limit 3 120
exec /mnt/us/dashboard/dashboard.sh run
EOF
            echo "   wrote $UPSTART_JOB"
        else
            rm -f "$UPSTART_JOB"
            echo "   removed $UPSTART_JOB"
        fi
        initctl reload-configuration 2>/dev/null || initctl reload 2>/dev/null
        mntroot ro 2>/dev/null
    else
        echo "   !! mntroot rw failed; autostart not changed"
    fi
fi

# --- 5. start --------------------------------------------------------------
if [ "$DO_START" = "1" ]; then
    echo "-- starting dashboard"
    sh "$DASH_DIR/dashboard.sh" restart
    sleep 1
    sh "$DASH_DIR/dashboard.sh" status
fi

echo
echo "Done."
echo "  Start / stop later from  KUAL -> Dashboard"
echo "  Revert everything with   sh $DASH_DIR/uninstall.sh"
echo "  Log:                     $LOG_FILE"
