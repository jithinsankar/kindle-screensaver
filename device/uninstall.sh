#!/bin/sh
# ============================================================================
#  Uninstaller -- restores the Kindle's normal standby behaviour.
#
#     sh /mnt/us/dashboard/uninstall.sh            stop + uninstall, keep files
#     sh /mnt/us/dashboard/uninstall.sh --purge    also delete /mnt/us/dashboard
#
#  This never modified your screensaver wallpapers, so "revert" simply means:
#  stop drawing, un-freeze the window manager, put the powerd properties back
#  the way they were, and hand the home screen back to the framework.
# ============================================================================

set -u

DASH_DIR=$(dirname "$0")
[ -r "$DASH_DIR/config.sh" ] || DASH_DIR=/mnt/us/dashboard
. "$DASH_DIR/config.sh"
. "$DASH_DIR/lib/util.sh"

EXT_DIR="/mnt/us/extensions/dashboard"
UPSTART_JOB="/etc/upstart/dashboard.conf"

PURGE=0
for a in "$@"; do
    case "$a" in
        --purge) PURGE=1 ;;
        *) echo "unknown option: $a"; exit 2 ;;
    esac
done

echo "== Kindle Lockscreen Dashboard uninstaller =="

# --- 1. stop and release the screen ---------------------------------------
if [ -r "$DASH_DIR/dashboard.sh" ]; then
    sh "$DASH_DIR/dashboard.sh" stop
else
    # dashboard.sh already deleted: reproduce the essential cleanup by hand.
    if [ -r "$STATE_DIR/dashboard.pid" ]; then
        kill "$(cat "$STATE_DIR/dashboard.pid")" 2>/dev/null
        rm -f "$STATE_DIR/dashboard.pid"
    fi
    killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    restore_power_originals
    cd / 2>/dev/null
    /etc/init.d/framework start 2>/dev/null
fi

# --- 2. boot autostart ----------------------------------------------------
if [ -f "$UPSTART_JOB" ]; then
    echo "-- removing $UPSTART_JOB"
    if mntroot rw 2>/dev/null; then
        rm -f "$UPSTART_JOB"
        initctl reload-configuration 2>/dev/null || initctl reload 2>/dev/null
        mntroot ro 2>/dev/null
    else
        echo "   !! mntroot rw failed; remove $UPSTART_JOB manually"
    fi
fi

# --- 3. KUAL extension ----------------------------------------------------
if [ -d "$EXT_DIR" ]; then
    echo "-- removing KUAL extension"
    rm -rf "$EXT_DIR" 2>/dev/null
fi

# --- 4. hand the screen back ---------------------------------------------
# Redraw the home screen so the stock wallpaper/screensaver behaviour resumes.
killall -CONT awesome 2>/dev/null
lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
cd / 2>/dev/null
/etc/init.d/framework restart 2>/dev/null

# --- 5. optionally delete the payload ------------------------------------
if [ "$PURGE" = "1" ]; then
    echo "-- purging $DASH_DIR"
    rm -rf "$DASH_DIR" 2>/dev/null
    echo "   (this script deleted itself; that is expected)"
fi

echo
echo "Done. The Kindle will behave exactly as it did before"
echo "  - screensaver / wallpaper restored"
echo "  - powerd properties restored from $STATE_DIR/original-powerd.txt"
echo "  - KUAL menu entry removed"
