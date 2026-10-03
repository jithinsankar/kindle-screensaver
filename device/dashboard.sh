#!/bin/sh
# ============================================================================
#  Kindle Lockscreen Dashboard - main entry point
#
#  Usage:
#     sh dashboard.sh start     run in the background
#     sh dashboard.sh stop      stop and hand the screen back to the Kindle UI
#     sh dashboard.sh restart
#     sh dashboard.sh run       run in the foreground (used by upstart)
#     sh dashboard.sh once      fetch + repaint once, then exit
#     sh dashboard.sh status    show state, powerd state, recent log
#     sh dashboard.sh probe     report what this device supports
# ============================================================================

# --- locate ourselves ------------------------------------------------------
DASH_DIR=$(dirname "$0")
if [ ! -r "$DASH_DIR/config.sh" ]; then
    DASH_DIR=/mnt/us/dashboard
fi
[ -r "$DASH_DIR/config.sh" ] && . "$DASH_DIR/config.sh"
[ -r "$DASH_DIR/lib/util.sh" ] && . "$DASH_DIR/lib/util.sh"
[ -r "$DASH_DIR/lib/weather.sh" ] && . "$DASH_DIR/lib/weather.sh"
[ -r "$DASH_DIR/lib/render.sh" ] && . "$DASH_DIR/lib/render.sh"
[ -r "$DASH_DIR/lib/anim.sh" ] && . "$DASH_DIR/lib/anim.sh"
[ -r "$DASH_DIR/lib/update.sh" ] && . "$DASH_DIR/lib/update.sh"

LOG_DIR=$(dirname "${LOG_FILE:-/mnt/us/dashboard/log/dashboard.log}")
PID_FILE="${STATE_DIR:-/mnt/us/dashboard/state}/dashboard.pid"

# --- process management ----------------------------------------------------
is_running() {
    [ -r "$PID_FILE" ] || return 1
    _p=$(cat "$PID_FILE" 2>/dev/null | tr -d ' \r\n')
    is_int "$_p" || return 1
    [ -d "/proc/$_p" ] || return 1
    tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q 'dashboard\.sh' || return 1
    return 0
}
running_pid() { cat "$PID_FILE" 2>/dev/null | tr -d ' \r\n'; }

# --- screen handling -------------------------------------------------------
# Taking the screen away from the framework. 'wm' follows what KOReader does on
# this firmware. All three parts are needed:
#   * disableEnablePillow   stops the status bar being managed
#   * interrogatePillow     actually HIDES it; on FW >= 5.7.2 disabling alone is
#                           not enough and the bar keeps refreshing its clock
#   * SIGSTOP awesome       the window manager
#   * SIGSTOP cvm           the VM that renders the home screen and the KUAL
#                           booklet -- WITHOUT this, cvm repaints over us
#                           everywhere our frames do not cover, which is why the
#                           panel showed the stock UI around the animation.
hold_screen() {
    case "${SCREEN_HOLD:-wm}" in
        wm)
            lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
            lipc-set-prop com.lab126.pillow interrogatePillow \
                '{"pillowId": "default_status_bar", "function": "nativeBridge.hideMe();"}' 2>/dev/null
            killall -STOP awesome 2>/dev/null
            killall -STOP cvm 2>/dev/null
            log "screen: held (pillow disabled+hidden, awesome and cvm SIGSTOPped)"
            ;;
        framework)
            log "screen: stopping the framework"
            /etc/init.d/framework stop 2>/dev/null
            stop lab126_gui 2>/dev/null
            sleep 2
            ;;
        *)
            log "screen: no hold requested"
            ;;
    esac
    # Inhibit USBMS so plugging in a cable does not switch the Kindle to
    # drive mode and tear the dashboard down. Only affects the driver, and is
    # undone in release_screen.
    if [ "${INHIBIT_USBMS:-0}" = "1" ]; then
        killall -STOP volumd 2>/dev/null && log "screen: volumd SIGSTOPped (USBMS inhibited)"
    fi
    return 0
}

# Give the screen back. Safe to call when nothing was held, and called from
# both the signal handler and cmd_stop so a hard kill cannot leave the Kindle
# with a frozen window manager.
release_screen() {
    killall -CONT volumd 2>/dev/null
    case "${SCREEN_HOLD:-wm}" in
        wm)
            # cvm and awesome first, so the framework can redraw as soon as it
            # is told to; order matters if the home screen launch fails.
            killall -CONT cvm 2>/dev/null
            killall -CONT awesome 2>/dev/null
            lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
            lipc-set-prop com.lab126.pillow interrogatePillow \
                '{"pillowId": "default_status_bar", "function": "nativeBridge.showMe();"}' 2>/dev/null
            lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
            ;;
        framework)
            cd / 2>/dev/null
            /etc/init.d/framework start 2>/dev/null
            ;;
        *) ;;
    esac
    return 0
}

# --- fonts -----------------------------------------------------------------
FONT_TEXT_RESOLVED=""
FONT_CARD_RESOLVED=""

resolve_fonts() {
    FONT_TEXT_RESOLVED=$(pick_font "${FONT_TEXT:-}" \
        "/mnt/us/koreader/fonts/noto/NotoSans-Regular.ttf,/usr/java/lib/fonts/NotoSans-Regular.ttf,/usr/java/lib/fonts/Caecilia_LT_65_Medium.ttf,/mnt/us/koreader/fonts/freefont/FreeSans.ttf")
    FONT_CARD_RESOLVED=$(pick_font "${FONT_CARD:-}" \
        "/mnt/us/koreader/fonts/noto/NotoSansCJKsc-Regular.otf,/mnt/us/koreader/fonts/freefont/FreeSans.ttf,/mnt/us/koreader/fonts/noto/NotoSans-Regular.ttf")
    log "font: text='${FONT_TEXT_RESOLVED:-<bitmap>}' card='${FONT_CARD_RESOLVED:-<bitmap>}'"
    if [ -z "$FONT_CARD_RESOLVED" ]; then
        log "font: WARNING card font not found -- weather glyphs will not render"
    fi
}

# Probe the card font for real. NotoSansCJKsc is a 16MB CFF-based .otf, and if
# this fbink build cannot render it then every card line silently drops to the
# bitmap font in the wrong size. Better to find out here and fall back cleanly.
resolve_card_font() {
    [ -n "$FONT_CARD_RESOLVED" ] || return 0
    if probe_font "$FONT_CARD_RESOLVED"; then
        log "font: card font renders OK"
        return 0
    fi
    log "font: WARNING fbink cannot render '$FONT_CARD_RESOLVED'"
    _alt=$(pick_font "" "/mnt/us/koreader/fonts/noto/NotoSans-Regular.ttf,/mnt/us/koreader/fonts/freefont/FreeSans.ttf")
    if [ -n "$_alt" ] && probe_font "$_alt"; then
        FONT_CARD_RESOLVED="$_alt"
        SHOW_ICONS=0
        log "font: using '$_alt' for cards, icons disabled"
    else
        log "font: no usable card font; cards will use the bitmap font"
        FONT_CARD_RESOLVED=""
    fi
    return 0
}

# --- escape hatch ----------------------------------------------------------
# While the window manager is frozen, tapping the screen is the only way back to
# the Kindle UI. TAP_COUNT taps within TAP_WINDOW seconds stops the daemon.
#
# Raw input_event, 32-bit Linux, 16 bytes little-endian:
#   [0..3] tv_sec   [4..7] tv_usec   [8..9] type   [10..11] code   [12..15] value
# `od -An -tu1` prints those 16 bytes as shell arguments $1..$16.
watch_for_exit() {
    _pid="$1"
    _dev=$(find_touch_device) || return 1
    log "escape: watching $_dev for ${TAP_COUNT:-3} taps in ${TAP_WINDOW:-3}s"

    _taps=0
    _first=0
    while :; do
        # Blocks until an event arrives. dd on an evdev node always returns
        # whole 16-byte structs, so there is no desync risk from stopping here.
        _ev=$(dd if="$_dev" bs=16 count=1 2>/dev/null | od -An -tu1 2>/dev/null)
        if [ -z "$_ev" ]; then
            sleep 1
            continue
        fi

        set -- $_ev
        [ $# -ge 16 ] || continue

        # EV_KEY(1) / BTN_TOUCH(330) / value 1 == finger down
        _dec=$(decode_evdev_event "$_ev") || continue
        _type=${_dec%% *}
        _rest=${_dec#* }
        _code=${_rest%% *}
        _val=${_rest##* }
        [ "$_type" = "1" ] && [ "$_code" = "330" ] && [ "$_val" = "1" ] || continue

        _now=$(date +%s)
        if [ $(( _now - _first )) -le "${TAP_WINDOW:-3}" ]; then
            _taps=$(( _taps + 1 ))
        else
            _taps=1
            _first=$_now
        fi
        log "escape: tap $_taps/${TAP_COUNT:-3}"

        if [ "$_taps" -ge "${TAP_COUNT:-3}" ]; then
            log "escape: tapped -- stopping the dashboard"
            touch "$STATE_DIR/stop-requested" 2>/dev/null
            kill -TERM "$_pid" 2>/dev/null
            return 0
        fi

        [ -d "/proc/$_pid" ] || return 0
    done
}

# Signal handler. Must always hand the screen back, otherwise a killed daemon
# would leave the Kindle with a frozen window manager.
on_stop() {
    log "daemon: stopping (signal)"
    release_screen
    restore_power_originals
    if [ -r "$STATE_DIR/watcher.pid" ]; then
        kill "$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)" 2>/dev/null
        rm -f "$STATE_DIR/watcher.pid" 2>/dev/null
    fi
    rm -f "$PID_FILE" 2>/dev/null
    exit 0
}

# --- self-update -----------------------------------------------------------
# Run at a start, before anything is launched. Doing it here rather than later
# means the daemon is started from the NEW files, and nothing is replaced while
# it is executing. A failure is never fatal: the installed version keeps working.
update_on_start_if_due() {
    command -v update_due >/dev/null 2>&1 || return 0
    update_due || return 0
    log "update: checking for a new version (UPDATE_ON_START=1)"
    find_http >/dev/null 2>&1
    if update_run; then
        log "update: applied"
    else
        log "update: skipped or failed, continuing with the installed version"
    fi
    return 0
}

cmd_update() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    find_fbink >/dev/null 2>&1
    find_http >/dev/null 2>&1 || log "update: WARNING no curl or wget found"

    _was_running=0
    is_running && _was_running=1

    if ! update_run; then
        echo "update failed -- see $LOG_FILE"
        return 1
    fi

    if [ "$_was_running" = "1" ]; then
        # Restart so the running daemon picks up the new code.
        log "update: restarting to apply"
        cmd_restart
    else
        echo "updated -- start the dashboard to use it"
    fi
    return 0
}

# Artwork is fetched separately from the code: the updater requires this whole
# project's layout, so an art-only archive would be rejected by it.
art_on_start_if_due() {
    command -v art_due >/dev/null 2>&1 || return 0
    art_due || return 0
    log "art: fetching artwork at start (ART_ON_START=1)"
    find_http >/dev/null 2>&1
    if art_run; then
        log "art: applied"
    else
        log "art: skipped or failed, keeping the installed frames"
    fi
    return 0
}

cmd_art() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    find_fbink >/dev/null 2>&1
    find_http >/dev/null 2>&1 || { echo "no curl or wget available"; return 1; }
    if art_run; then
        echo "artwork updated -- restart the animation to use it"
        return 0
    fi
    echo "artwork fetch failed -- see $LOG_FILE"
    return 1
}

# --- choosing between installed artworks ------------------------------------
# Every artwork is its own directory, so they coexist and a new one never replaces
# an old one. These commands only change WHICH one plays; they never touch frames.
cmd_sets() {
    _base=$(anim_base)
    _active=$(active_set)
    echo "animations in $_base:"
    _any=0
    for _d in "$_base"/*/; do
        [ -d "$_d" ] || continue
        _n=$(basename "$_d")
        _c=$(anim_count_in "$_d")
        if [ "$_c" -lt 2 ]; then
            echo "  $_n  (ignored: only $_c frame(s))"
            continue
        fi
        if [ "$_n" = "$_active" ]; then
            echo "  * $_n  ($_c frames)  <- active"
        else
            echo "    $_n  ($_c frames)"
        fi
        _any=1
    done
    [ "$_any" = "1" ] || echo "  (none installed)"
    echo "active set: $_active"
    return 0
}

cmd_use() {
    _want="$1"
    _base=$(anim_base)
    if [ -z "$_want" ]; then
        echo "usage: $0 use <set>"
        cmd_sets
        return 2
    fi
    if [ ! -d "$_base/$_want" ]; then
        echo "no such animation: $_want"
        cmd_sets
        return 1
    fi
    _c=$(anim_count_in "$_base/$_want")
    if [ "$_c" -lt 2 ]; then
        echo "$_want has only $_c frame(s); refusing to make it active"
        return 1
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "$_want" > "$STATE_DIR/active-set"
    log "anim: active set is now '$_want' ($_c frames)"
    echo "active animation: $_want"
    return 0
}

# Step to the next installed set, wrapping round. This is the KUAL action, so you
# can move between artworks without editing config or plugging the Kindle in.
cmd_next_anim() {
    _base=$(anim_base)
    _cur=$(active_set)
    _names=""
    for _d in "$_base"/*/; do
        [ -d "$_d" ] || continue
        _n=$(basename "$_d")
        _c=$(anim_count_in "$_d")
        [ "$_c" -ge 2 ] || continue
        _names="$_names $_n"
    done
    set -- $_names
    [ $# -gt 0 ] || { echo "no animations installed"; return 1; }

    _next="$1"
    _seen=0
    for _n in "$@"; do
        if [ "$_seen" = "1" ]; then
            _next="$_n"
            _seen=2
            break
        fi
        [ "$_n" = "$_cur" ] && _seen=1
    done
    # _seen=2 means we found a following set; otherwise we wrapped to the first.
    cmd_use "$_next"
}

# --- weather ---------------------------------------------------------------
fetch_all() {
    _i=0
    printf '%s\n' "$LOCATIONS" | while IFS='|' read -r _label _lat _lon _tz; do
        [ -n "$_label" ] || continue
        case "$_label" in \#*) continue ;; esac   # allow # comments
        weather_fetch "$_i" "$_label" "$_lat" "$_lon" "$_tz" \
            || log "wx[$_i] keeping previous cache for '$_label'"
        _i=$(( _i + 1 ))
    done
}

# --- main loop -------------------------------------------------------------
# Draw a short message using the TEXT font, which works even on a build whose
# image support is disabled. Used to explain a refusal without leaving the user
# staring at a blank panel with no idea what happened.
show_notice() {
    [ -n "$FBINK" ] || return 0
    resolve_fonts 2>/dev/null
    "$FBINK" -q -c -B "${C_BG:-WHITE}" 2>>"$LOG_FILE"
    _y=120
    for _line in "$@"; do
        if [ -n "$FONT_TEXT_RESOLVED" ]; then
            "$FBINK" -q -b -m -C "${C_PRIMARY:-BLACK}" \
                -t "regular=$FONT_TEXT_RESOLVED,px=30,top=$_y,left=40,right=40" \
                "$_line" 2>>"$LOG_FILE"
        else
            "$FBINK" -q -b -m -C "${C_PRIMARY:-BLACK}" -y "$(( _y / 28 ))" "$_line" 2>>"$LOG_FILE"
        fi
        _y=$(( _y + 52 ))
    done
    # Plain -s -f rather than -W: a stripped build is the likelier failure here,
    # so use the fewest options that still force a full repaint.
    "$FBINK" -q -s -f 2>>"$LOG_FILE"
    return 0
}

# Standalone animation mode: the frames own the panel, so there is no clock and
# no second writer. Invoked in the foreground from KUAL, exactly like KOReader's
# own KUAL launcher, and exited by tapping the screen.
cmd_anim() {
    trap '' HUP
    trap on_stop TERM INT

    mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    log "=== animation mode starting (pid $$) ==="

    find_fbink || { log "FATAL: no fbink binary found"; return 1; }
    update_on_start_if_due
    # Before anim_prepare, which probes the frames: a fresh set should be used.
    art_on_start_if_due

    # Verify BEFORE touching the screen. find_fbink's search order prefers the
    # KOReader build, which is stripped with image support DISABLED: it draws
    # text fine but every frame fails, so clearing the panel first would leave
    # it blank for minutes. That is exactly how this first failed on hardware.
    if ! anim_prepare; then
        log "anim: refusing to start -- the screen was left untouched"
        show_notice "Animation unavailable" \
                    "No fbink build on this device can" \
                    "draw images. The KOReader build has" \
                    "image support disabled at compile time." \
                    "See dashboard/log/dashboard.log"
        return 1
    fi

    # Same safety rule as the dashboard: never take the screen unless a tap can
    # be detected to give it back.
    _self=$$
    if [ "${TAP_TO_EXIT:-1}" = "1" ] && escape_available; then
        ( watch_for_exit "$_self" ) &
        printf '%s\n' "$!" > "$STATE_DIR/watcher.pid" 2>/dev/null
    else
        log "escape: no tap detection -- refusing to freeze the window manager"
        SCREEN_HOLD=none
    fi

    save_power_originals
    hold_screen
    set_power_prevent
    apply_frontlight
    printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null

    if [ "${ANIM_EVERY_SECONDS:-0}" -gt 0 ]; then
        log "anim: cadence = ${ANIM_BURST_SECONDS:-8}s flapping, then ${ANIM_EVERY_SECONDS}s holding one still frame"
        log "anim: NOTE a held e-ink frame looks identical to a crash; set ANIM_EVERY_SECONDS=0 for continuous"
    else
        log "anim: cadence = continuous (ANIM_EVERY_SECONDS=0)"
    fi

    # Say which animation is playing. The KUAL entry is deliberately named just
    # "Start animation" -- the set can be anything, so hardcoding a name there
    # would be wrong the moment it changes. The log is where the name belongs.
    log "anim: playing set '$(active_set)' ($(anim_count) frames) from $(anim_dir)"

    while :; do
        # Reclaim the whole panel first: frames only cover their own rectangle,
        # so anything the framework painted would otherwise stay visible.
        anim_reclaim
        anim_burst "${ANIM_BURST_SECONDS:-8}"
        if [ "$?" -eq 2 ]; then
            # Frames stopped drawing. Give up rather than looping over a blank
            # screen forever.
            log "anim: stopping after repeated draw failures"
            show_notice "Animation stopped" \
                        "Frames stopped drawing." \
                        "See dashboard/log/dashboard.log"
            break
        fi
        # ANIM_EVERY_SECONDS=0 means keep animating without a rest period.
        if [ "${ANIM_EVERY_SECONDS:-0}" -gt 0 ]; then
            # Settle on one frame: between bursts the panel is static and free.
            # Logged explicitly so a still panel is not read as a hang.
            anim_rest
            log "anim: holding a still frame for ${ANIM_EVERY_SECONDS}s"
            sleep "${ANIM_EVERY_SECONDS:-0}"
        fi
    done

    release_screen
    restore_power_originals
    rm -f "$PID_FILE" 2>/dev/null
    log "=== animation mode finished ==="
    return 0
}

cmd_run() {
    trap '' HUP
    trap on_stop TERM INT

    mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    log "=== dashboard starting (pid $$) ==="

    find_fbink || { log "FATAL: no fbink binary found"; echo "no fbink"; return 1; }
    log "fbink: $FBINK"
    find_http || log "WARN: neither curl nor wget found; weather will fail"
    resolve_fonts
    resolve_card_font

    # Safety rule: freezing the window manager removes the only route back to
    # the Kindle UI, so only do it when we can actually detect a tap to undo it.
    _self=$$
    if [ "${TAP_TO_EXIT:-1}" = "1" ] && escape_available; then
        ( watch_for_exit "$_self" ) &
        printf '%s\n' "$!" > "$STATE_DIR/watcher.pid" 2>/dev/null
    else
        case "${TAP_TO_EXIT:-1}" in
            1) log "escape: no touchscreen or no od -- cannot detect a tap" ;;
            *) log "escape: TAP_TO_EXIT=0, not starting the tap watcher" ;;
        esac
        case "${SCREEN_HOLD:-wm}" in
            wm|framework)
                log "escape: refusing to take the screen with no way to give it back;"
                log "escape: falling back to SCREEN_HOLD=none so KUAL stays usable"
                SCREEN_HOLD="none"
                ;;
        esac
    fi

    save_power_originals
    hold_screen
    set_power_prevent
    apply_frontlight
    sync_time
    fetch_all
    render_full

    _elapsed=0
    while :; do
        sleep "${CLOCK_INTERVAL:-60}"
        reset_idle_timer
        _elapsed=$(( _elapsed + ${CLOCK_INTERVAL:-60} ))
        if [ "$_elapsed" -ge "${WEATHER_INTERVAL:-900}" ]; then
            _elapsed=0
            set_power_prevent          # re-assert; the framework resets this
            sync_time
            fetch_all
            render_full
            log "cycle: full refresh done"
        else
            render_clock_only
        fi
    done
}

# --- commands --------------------------------------------------------------
cmd_start() {
    if is_running; then
        log "start: already running (pid $(running_pid))"
        return 0
    fi
    mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    log_trim
    rm -f "$STATE_DIR/stop-requested" 2>/dev/null
    update_on_start_if_due
    art_on_start_if_due
    sh "$DASH_DIR/dashboard.sh" run >> "$LOG_FILE" 2>&1 < /dev/null &
    _pid=$!
    printf '%s\n' "$_pid" > "$PID_FILE"
    log "start: launched pid $_pid"
    return 0
}

cmd_stop() {
    # Stop the tap watcher first; it may be blocked reading the touchscreen.
    if [ -r "$STATE_DIR/watcher.pid" ]; then
        kill "$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)" 2>/dev/null
        rm -f "$STATE_DIR/watcher.pid" 2>/dev/null
    fi

    if is_running; then
        _p=$(running_pid)
        log "stop: terminating pid $_p"
        kill "$_p" 2>/dev/null
        _n=0
        while [ -d "/proc/$_p" ] && [ "$_n" -lt 6 ]; do
            sleep 1
            _n=$(( _n + 1 ))
        done
        if [ -d "/proc/$_p" ]; then
            log "stop: pid $_p did not exit, sending KILL"
            kill -9 "$_p" 2>/dev/null
        fi
    else
        log "stop: not running"
    fi
    # Always run these, even if the daemon was killed hard.
    release_screen
    restore_power_originals
    rm -f "$PID_FILE" 2>/dev/null
    return 0
}

cmd_restart() { cmd_stop; sleep 1; cmd_start; }

cmd_once() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    find_fbink || { echo "no fbink found"; return 1; }
    find_http
    resolve_fonts
    fetch_all
    render_full
    log "once: rendered with $FBINK"
    echo "rendered (fbink: $FBINK)"
    echo "fonts: text='$FONT_TEXT_RESOLVED' card='$FONT_CARD_RESOLVED'"
}

cmd_probe() {
    echo "=== dashboard probe ==="
    echo "dash dir   : $DASH_DIR"
    find_fbink && echo "fbink      : $FBINK" || echo "fbink      : NOT FOUND"
    find_http && echo "http       : curl='$CURL_BIN' wget='$WGET_BIN'" || echo "http       : NOT FOUND"
    resolve_fonts
    echo "font text  : ${FONT_TEXT_RESOLVED:-<none>}"
    echo "font card  : ${FONT_CARD_RESOLVED:-<none>}"
    echo "http date  : $(http_date_header 'https://api.open-meteo.com/v1/forecast?latitude=0&longitude=0')"
    if command -v update_archive_url >/dev/null 2>&1; then
        echo "update      : on_start=${UPDATE_ON_START:-0} ref=${UPDATE_REF:-main} repo=${UPDATE_REPO:-<unset>}"
        echo "update url  : $(update_archive_url 2>/dev/null || echo '<not configured>')"
        if [ -r "$STATE_DIR/last-update" ]; then
            echo "last update : $(date -d @$(cat "$STATE_DIR/last-update" 2>/dev/null) 2>/dev/null || cat "$STATE_DIR/last-update" 2>/dev/null)"
        else
            echo "last update : never"
        fi
    fi
    printf 'powerd     :'
    for p in preventScreenSaver preventSuspend stayAwake touchScreenSaverTimeout \
             flIntensity isCharging state; do
        printf ' %s=%s' "$p" "$(lipc-get-prop -i com.lab126.powerd "$p" 2>/dev/null | tr -d '\r')"
    done
    echo
    echo "=== end probe ==="
}

# Report fbink's real geometry so layout constants can be checked rather than
# guessed. This is the command to run when something is mispositioned.
cmd_geo() {
    echo "=== geometry probe ==="
    find_fbink || { echo "fbink: NOT FOUND"; return 1; }
    resolve_fonts
    echo "fbink      : $FBINK"
    echo "font text  : ${FONT_TEXT_RESOLVED:-<none>}"
    echo "font card  : ${FONT_CARD_RESOLVED:-<none>}"
    echo
    echo "--- screen state (fbink -e) ---"
    "$FBINK" -e 2>&1 | tr ';' '\n' | grep -E 'screenWidth|screenHeight|viewWidth|viewHeight|DPI|BPP' 2>/dev/null
    echo
    echo "--- measured advance, same font at several sizes (drawn at top=100) ---"
    for _px in 22 24 52 200; do
        _out=$("$FBINK" -q -b -E -m -O \
            -t "regular=$FONT_TEXT_RESOLVED,px=$_px,top=100,left=20,right=20" \
            "Hg 20:53" 2>&1)
        printf 'px=%-4s %s\n' "$_px" "${_out:-<no output from -E>}"
    done
    echo
    echo "--- derived layout for the current config ---"
    for _px in 22 24 52 200; do
        printf 'px=%-4s fallback advance = %s\n' "$_px" \
            "$(printf '%s' "$_px" | awk -v f="${FALLBACK_LINE_FACTOR:-1.45}" '{ printf "%d", $1 * f }')"
    done
    echo "DATE_TOP=${DATE_TOP:-20} CLOCK_GAP=${CLOCK_GAP:-6} CLOCK_PX=${CLOCK_PX:-200}"
    echo "CARD1_TOP=${CARD1_TOP:-370} CARD2_TOP=${CARD2_TOP:-562} CARD_HEIGHT=${CARD_HEIGHT:-176} FOOTER_TOP=${FOOTER_TOP:-750}"
    echo "--- last paint ---"
    echo "clock top=${CLOCK_TOP_ACTUAL:-?} band top=${CLOCK_BAND_TOP:-?} band height=${CLOCK_BAND_HEIGHT:-?}"
    if [ -r "$LOG_FILE" ]; then
        echo "--- OpenType or fallback problems in the log ---"
        grep -E 'OpenType failed|using .* for cards|no usable card font|cannot render' "$LOG_FILE" \
            | tail -n 10 || echo "(none)"
    fi
    echo "=== end geometry probe ==="
}

cmd_status() {
    if is_running; then
        echo "running      : yes (pid $(running_pid))"
    else
        echo "running      : no"
    fi
    echo "powerd state : $(lipc-get-prop com.lab126.powerd state 2>/dev/null | tr -d '\r')"
    echo "screen hold  : ${SCREEN_HOLD:-wm}"
    echo "touchscreen  : $(find_touch_device 2>/dev/null || echo 'not found')"
    echo "tap to exit  : $(if escape_available; then echo "yes (${TAP_COUNT:-3} taps)"; else echo 'NO -- KUAL is your only way back'; fi)"
    if command -v anim_dir >/dev/null 2>&1; then
        _adir=$(anim_dir)
        _acount=$(anim_count)
        _nsets=$(anim_list 2>/dev/null | wc -l | tr -d ' ')
        echo "animation    : set='$(active_set)' frames=${_acount:-0}"
        echo "anim sets    : ${_nsets:-0} installed in $(anim_base)"
        echo "anim dir     : $_adir"
        if [ "${_nsets:-0}" -gt 1 ]; then
            echo "anim list    : $(anim_list 2>/dev/null | awk '{printf "%s ", $1}')"
        fi
        if [ "${ANIM_EVERY_SECONDS:-0}" -gt 0 ]; then
            echo "anim cadence : ${ANIM_BURST_SECONDS:-8}s flapping, then ${ANIM_EVERY_SECONDS}s holding one frame"
        else
            echo "anim cadence : continuous"
        fi
    fi
    if [ -f "$STATE_DIR/stop-requested" ]; then
        echo "note         : last stop was requested by tapping the screen"
    fi
    echo "log tail     :"
    [ -r "$LOG_FILE" ] && tail -n 15 "$LOG_FILE"
}

case "$1" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    run)     cmd_run ;;
    once)    cmd_once ;;
    anim)    cmd_anim ;;
    update)  cmd_update ;;
    art)     cmd_art ;;
    sets)    cmd_sets ;;
    use)     cmd_use "$2" ;;
    next)    cmd_next_anim ;;
    probe)   cmd_probe ;;
    geo)     cmd_geo ;;
    status|"") cmd_status ;;
    *)
        echo "usage: $0 {start|stop|restart|run|once|anim|update|art|sets|use <set>|next|status|probe|geo}"
        exit 2
        ;;
esac
