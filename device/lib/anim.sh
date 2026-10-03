#!/bin/sh
# ============================================================================
#  Looping image animation for an e-ink panel.
#
#  fbink has no animation player: it draws one static image per invocation. So
#  an animation here is a numbered frame sequence replayed by this loop. Three
#  things make that viable on e-ink, and all three matter:
#
#   1. The A2 waveform updates in roughly 50-150ms with no black flash, where a
#      GC16 full refresh costs 300-800ms and flashes the whole panel. A2 is
#      effectively 1-bit, which is why frames must be pure black and white.
#   2. Each frame is drawn at a fixed x,y, so fbink damages only that rectangle
#      instead of the whole screen.
#   3. A2 accumulates ghosting, so a periodic full GC16 flash is required. It is
#      visible, and ANIM_DEGHOST_SECONDS controls how often it happens.
#
#  What this cannot do is be fast. Realistically the panel manages 5-10 fps, so
#  design for a slow deliberate flutter rather than a frantic one.
# ============================================================================

# ANIM_READY caches the successful renderer probe; ANIM_FAILS counts consecutive
# draw failures so a broken build cannot be looped over forever.
ANIM_LOOPS=0
ANIM_FAILS=0
ANIM_READY=""
ANIM_LAST_DEGHOST=0

# Where all the installed sets live.
anim_base() {
    printf '%s' "${ANIM_DIR_BASE:-/mnt/us/dashboard/animations}"
}

# Count the frames in a specific directory.
anim_count_in() {  # $1 = directory
    _n=0
    for _f in "$1"/${ANIM_FRAME_GLOB:-frame_*.png}; do
        [ -f "$_f" ] || continue
        _n=$(( _n + 1 ))
    done
    printf '%s' "$_n"
}

# Which installed set to play. Resolution order:
#   1. state/repo-active -- what the ARTWORK REPO declares in its config.json,
#      recorded at fetch time. This is the intended way to choose when a repo
#      holds many artworks: edit one line on GitHub rather than tapping through a
#      list on the device. It wins over a local choice, so editing the repo has a
#      visible effect; remove "active" from config.json to take local control.
#   2. state/active-set -- a local override, written by `dashboard.sh use` or the
#      KUAL "Next animation" action
#   3. ANIM_SET from config (the device default)
#   4. whichever set is actually installed first
#
# Every artwork lives in its own directory, so adding a new one NEVER replaces an
# existing one. Only reusing the same folder name replaces it, which is how you
# update an artwork you already have.
active_set() {
    _base=$(anim_base)
    _sdir="${STATE_DIR:-/mnt/us/dashboard/state}"
    _f="$_sdir/repo-active"
    if [ -r "$_f" ]; then
        _s=$(tr -d ' \r\n' < "$_f" 2>/dev/null)
        if [ -n "$_s" ] && [ -d "$_base/$_s" ]; then
            printf '%s' "$_s"
            return 0
        fi
    fi
    _f="$_sdir/active-set"
    if [ -r "$_f" ]; then
        _s=$(tr -d ' \r\n' < "$_f" 2>/dev/null)
        if [ -n "$_s" ] && [ -d "$_base/$_s" ]; then
            printf '%s' "$_s"
            return 0
        fi
    fi
    if [ -n "${ANIM_SET:-}" ] && [ -d "$_base/$ANIM_SET" ]; then
        printf '%s' "$ANIM_SET"
        return 0
    fi
    for _d in "$_base"/*/; do
        [ -d "$_d" ] || continue
        basename "$_d"
        return 0
    done
    printf '%s' "${ANIM_SET:-bird}"
}

# Every usable installed set, as "name frames" lines, in name order.
anim_list() {
    _base=$(anim_base)
    for _d in "$_base"/*/; do
        [ -d "$_d" ] || continue
        _c=$(anim_count_in "$_d")
        [ "$_c" -ge 2 ] || continue
        printf '%s %s\n' "$(basename "$_d")" "$_c"
    done
}

# Where the frames live. ANIM_DIR is an explicit override -- a deployment or a
# test can point straight at one directory; otherwise it is the active set.
anim_dir() {
    if [ -n "${ANIM_DIR:-}" ]; then
        printf '%s' "$ANIM_DIR"
        return 0
    fi
    printf '%s/%s' "$(anim_base)" "$(active_set)"
}

# A frame set is self-describing: manifest.json carries its own frame size,
# position on the panel and suggested delay, so handing someone the folder is
# enough. See artwork/FORMAT.md. Flattened to one line because the sed-based JSON
# helpers (shared with the weather code) expect that.
ANIM_MF_X=""
ANIM_MF_Y=""
ANIM_MF_DELAY=""

anim_manifest_json() {
    _f="$(anim_dir)/${ANIM_MANIFEST:-manifest.json}"
    [ -r "$_f" ] || return 1
    tr -d '\n\r' < "$_f" 2>/dev/null
}

anim_load_manifest() {
    ANIM_MF_X=""; ANIM_MF_Y=""; ANIM_MF_DELAY=""
    [ "${ANIM_USE_MANIFEST:-1}" = "1" ] || return 0
    command -v json_section >/dev/null 2>&1 || return 0
    _json=$(anim_manifest_json) || {
        log "anim: no manifest.json -- using the config values for placement"
        return 0
    }
    _fr=$(json_section "$_json" frame)
    if [ -n "$_fr" ]; then
        ANIM_MF_X=$(json_num "$_fr" x)
        ANIM_MF_Y=$(json_num "$_fr" y)
    fi
    ANIM_MF_DELAY=$(json_num "$_json" delay_ms)
    is_int "$ANIM_MF_X" || ANIM_MF_X=""
    is_int "$ANIM_MF_Y" || ANIM_MF_Y=""
    is_int "$ANIM_MF_DELAY" || ANIM_MF_DELAY=""
    log "anim: manifest -> position ${ANIM_MF_X:-?},${ANIM_MF_Y:-?} delay ${ANIM_MF_DELAY:-?}ms"
    return 0
}

# Count the frames in the active set and echo the count; also sets
# ANIM_FRAME_COUNT for the status display.
anim_count() {
    _n=$(anim_count_in "$(anim_dir)")
    ANIM_FRAME_COUNT="$_n"
    printf '%s' "$_n"
}

anim_check() {
    _d=$(anim_dir)
    if [ ! -d "$_d" ]; then
        log "anim: missing frame directory: $_d"
        return 1
    fi
    _n=$(anim_count)
    if [ "$_n" -lt 2 ]; then
        log "anim: need at least 2 frames in $_d (found $_n)"
        return 1
    fi
    log "anim: $_n frames in $_d"
    return 0
}

# Confirm there is a renderer that can actually draw images, using the first
# frame as the probe. MUST be called before anything touches the screen: with no
# working renderer every frame fails and the result is a permanently blank
# panel, which is exactly how this feature first failed on real hardware.
anim_prepare() {
    anim_load_manifest
    anim_check || return 1
    _first=""
    for _f in "$(anim_dir)"/${ANIM_FRAME_GLOB:-frame_*.png}; do
        [ -f "$_f" ] || continue
        _first="$_f"
        break
    done
    [ -n "$_first" ] || { log "anim: no frames to probe with"; return 1; }
    find_fbink_image "$_first" >/dev/null || return 1
    ANIM_FAILS=0
    ANIM_READY=1
    ANIM_LAST_DEGHOST=$(date +%s)
    return 0
}

# Take the whole panel back. Frames only ever cover their own rectangle, so
# anywhere the framework repaints would show through forever. Re-clearing before
# each burst undoes any stray repaint.
anim_reclaim() {
    [ -n "${FBINK:-}" ] || return 0
    "$FBINK" -q -c -B "${C_BG:-WHITE}" 2>>"$LOG_FILE"
    return 0
}

# Where to draw. The set's manifest wins when it has one; the config values are
# the fallback for a set without a manifest.
anim_pos() {
    printf '%s %s' "${ANIM_MF_X:-${ANIM_X:-90}}" "${ANIM_MF_Y:-${ANIM_Y:-240}}"
}

# Draw one frame. Not batched: each frame must actually reach the panel.
# Uses the image-capable binary, which is not necessarily $FBINK.
anim_paint() {
    _f="$1"
    [ -n "${FBINK_IMG:-}" ] || return 1
    [ -f "$_f" ] || return 1
    set -- $(anim_pos)
    _x="$1"; _y="$2"
    "$FBINK_IMG" -q -g "file=$_f,x=$_x,y=$_y" -W "${ANIM_WAVEFORM:-A2}" 2>>"$LOG_FILE"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        ANIM_FAILS=0
    else
        ANIM_FAILS=$(( ANIM_FAILS + 1 ))
        log "anim: paint failed ($ANIM_FAILS consecutive) for $_f"
    fi
    return "$_rc"
}

# Full-screen flash, to clear the residue A2 leaves behind.
anim_deghost() {
    [ "${ANIM_DEGHOST_SECONDS:-120}" -gt 0 ] || return 0
    [ -n "${FBINK_IMG:-}" ] || return 0
    log "anim: deghost flash (loop $ANIM_LOOPS)"
    "$FBINK_IMG" -q -s -f -W "${ANIM_DEGHOST_WAVEFORM:-GC16}" 2>>"$LOG_FILE"
    return 0
}

# Ghosting accumulates with the fast waveform, so flash occasionally. Driven by
# ELAPSED TIME rather than loop count: the real frame rate varies by an order of
# magnitude between devices, so a loop count gives no control over how often the
# user actually sees a flash.
anim_deghost_due() {
    [ "${ANIM_DEGHOST_SECONDS:-120}" -gt 0 ] || return 1
    _now=$(date +%s)
    [ $(( _now - ANIM_LAST_DEGHOST )) -ge "${ANIM_DEGHOST_SECONDS:-120}" ] || return 1
    ANIM_LAST_DEGHOST="$_now"
    return 0
}

# Play complete cycles of the sequence until ANIM_BURST_SECONDS have elapsed.
# Cycles are never cut short, so the motion always resolves.
anim_burst() {
    _secs="${1:-${ANIM_BURST_SECONDS:-8}}"
    _d=$(anim_dir)
    _n=$(anim_count)
    [ "$_n" -ge 2 ] || { log "anim: no frames to play"; return 1; }

    _started=$(date +%s)
    _deadline=$(( _started + _secs ))
    _loop_started=$_started

    while [ "$(date +%s)" -lt "$_deadline" ]; do
        # A shell glob is already sorted, which is why frames are numbered.
        for _f in "$_d"/${ANIM_FRAME_GLOB:-frame_*.png}; do
            [ -f "$_f" ] || continue
            if ! anim_paint "$_f"; then
                # Give up after a few failures instead of looping forever over a
                # blank screen. Return 2 so the caller can restore and explain.
                if [ "$ANIM_FAILS" -ge "${ANIM_MAX_FAILURES:-3}" ]; then
                    log "anim: giving up after $ANIM_FAILS consecutive failures"
                    return 2
                fi
                return 1
            fi
            sleep_ms "${ANIM_MF_DELAY:-${ANIM_DELAY_MS:-120}}"
        done
        ANIM_LOOPS=$(( ANIM_LOOPS + 1 ))

        # Report the real rate. The panel update dominates, so this is the only
        # honest measurement of achievable fps on a given device -- and the
        # figure that tells you whether ANIM_DELAY_MS is even relevant.
        _now=$(date +%s)
        _dt=$(( _now - _loop_started ))
        _loop_started=$_now
        [ "$_dt" -lt 1 ] && _dt=1
        log "anim: loop $ANIM_LOOPS took ${_dt}s ($_n frames, ~$(( _dt * 1000 / _n ))ms per frame)"

        if anim_deghost_due; then
            anim_deghost
        fi
    done
    return 0
}

# Settle on one frame and stop moving, which is what makes burst mode cheap:
# between bursts the panel holds a static image and consumes nothing.
anim_rest() {
    _d=$(anim_dir)
    if [ -n "${ANIM_REST_FRAME:-}" ] && [ -f "$_d/$ANIM_REST_FRAME" ]; then
        anim_paint "$_d/$ANIM_REST_FRAME"
        return 0
    fi
    for _f in "$_d"/${ANIM_FRAME_GLOB:-frame_*.png}; do
        [ -f "$_f" ] || continue
        anim_paint "$_f"
        return 0
    done
    return 1
}
