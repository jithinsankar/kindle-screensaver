#!/bin/sh
# ============================================================================
#  Thin dispatcher invoked by the KUAL menu entry for this extension.
#  KUAL gives us no console, so diagnostics are painted onto the eInk panel.
# ============================================================================

DASH="/mnt/us/dashboard"
OUT_FILE="/mnt/us/dashboard/log/kual-last.txt"

find_fbink_here() {
    for d in /var/tmp /mnt/us/koreader /mnt/us/libkh/bin \
             /mnt/us/extensions/MRInstaller/bin/KHF; do
        if [ -x "$d/fbink" ]; then printf '%s' "$d/fbink"; return 0; fi
    done
    return 1
}

show_on_screen() {
    _fb=$(find_fbink_here) || return 0
    # fbink honours real linefeeds inside the string argument, so we can push a
    # whole diagnostic dump straight to the panel.
    "$_fb" -q -c "$1" 2>/dev/null
}

run_and_show() {
    _out=$("$@")
    mkdir -p "$(dirname "$OUT_FILE")" 2>/dev/null
    printf '%s\n' "$_out" > "$OUT_FILE" 2>/dev/null
    show_on_screen "$_out"
}

case "$1" in
    install)
        run_and_show sh "$DASH/install.sh"
        ;;
    uninstall)
        sh "$DASH/uninstall.sh"
        ;;
    autostart-on)
        run_and_show sh "$DASH/install.sh" --no-start --autostart
        ;;
    autostart-off)
        run_and_show sh "$DASH/install.sh" --no-start --no-autostart
        ;;
    autostart-toggle)
        # One menu entry instead of two, and the output names the resulting
        # state -- the menu label itself cannot show on/off.
        run_and_show sh "$DASH/install.sh" --no-start --toggle-autostart
        ;;
    probe)
        run_and_show sh "$DASH/dashboard.sh" probe
        ;;
    geo)
        run_and_show sh "$DASH/dashboard.sh" geo
        ;;
    status)
        run_and_show sh "$DASH/dashboard.sh" status
        ;;
    start|stop|restart|once)
        sh "$DASH/dashboard.sh" "$1"
        if [ "$1" != "once" ]; then
            sleep 1
            _out=$(sh "$DASH/dashboard.sh" status)
            mkdir -p "$(dirname "$OUT_FILE")" 2>/dev/null
            printf '%s\n' "$_out" > "$OUT_FILE" 2>/dev/null
        fi
        ;;
    anim)
        # Runs in the foreground until the screen is tapped three times, exactly
        # like KOReader's own KUAL launcher. KUAL stays blocked meanwhile.
        sh "$DASH/dashboard.sh" anim
        ;;
    update)
        run_and_show sh "$DASH/dashboard.sh" update
        ;;
    art)
        run_and_show sh "$DASH/dashboard.sh" art
        ;;
    sets)
        run_and_show sh "$DASH/dashboard.sh" sets
        ;;
    next)
        run_and_show sh "$DASH/dashboard.sh" next
        ;;
    *)
        show_on_screen "Dashboard: unknown action '$1'"
        ;;
esac
