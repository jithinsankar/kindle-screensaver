#!/bin/sh
# ============================================================================
#  Shared helpers: logging, fbink discovery, LIPC, network
# ============================================================================

# ---------------------------------------------------------------------------
# path defaults
#
# These are set by config.sh, which every entry point sources before this file.
# The defaults below exist for when it is missing, unreadable or truncated: an
# empty STATE_DIR sends every write to "/", and the Kindle's root is read-only, so
# the symptom is a bare "Permission denied" that says nothing about the real
# problem. ${VAR:-default} only fills in when the value is empty, so config.sh
# still always wins.
# ---------------------------------------------------------------------------
STATE_DIR="${STATE_DIR:-/mnt/us/dashboard/state}"
LOG_DIR="${LOG_DIR:-/mnt/us/dashboard/log}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/dashboard.log}"

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
log() {
    _msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    [ -n "$LOG_FILE" ] && printf '%s\n' "$_msg" >> "$LOG_FILE" 2>/dev/null
    [ -n "$DASH_VERBOSE" ] && printf '%s\n' "$_msg"
    return 0
}

log_trim() {
    # Keep the log from growing without bound. Cheap: only runs at start.
    [ -f "$LOG_FILE" ] || return 0
    _sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_sz" -gt "${LOG_MAX_BYTES:-262144}" ]; then
        tail -c "$((LOG_MAX_BYTES / 2))" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null \
            && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# fbink discovery
#
# /mnt/us is FAT32 and only executable because the WinterBreak jailbreak sets
# the MNTUS_EXEC flag. If that ever fails we copy the binary onto tmpfs and run
# it from there. Search order mirrors KOReader's own libkohelper.sh.
# ---------------------------------------------------------------------------
FBINK=""

find_fbink() {
    [ -n "$FBINK" ] && return 0
    for d in /var/tmp /var/tmp/kdash /mnt/us/koreader /mnt/us/libkh/bin \
             /mnt/us/extensions/MRInstaller/bin/KHF /mnt/us/linkss/bin; do
        if [ -x "$d/fbink" ]; then
            FBINK="$d/fbink"
            return 0
        fi
    done
    # Not executable in place -> stage it on tmpfs.
    for d in /mnt/us/libkh/bin /mnt/us/koreader \
             /mnt/us/extensions/MRInstaller/bin/KHF; do
        if [ -f "$d/fbink" ]; then
            mkdir -p /var/tmp/kdash 2>/dev/null
            if cp "$d/fbink" /var/tmp/kdash/fbink 2>/dev/null; then
                chmod 0755 /var/tmp/kdash/fbink 2>/dev/null
                FBINK="/var/tmp/kdash/fbink"
                return 0
            fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# image support is a SEPARATE capability from running fbink at all
# ---------------------------------------------------------------------------
# fbink is compiled with optional features, and the copy KOReader ships is
# stripped with IMAGE support disabled. It draws text perfectly, so find_fbink
# happily returns it -- and then every `-g, --image` call fails with:
#
#     [FBInk] Image support is disabled in this FBInk build!
#
# find_fbink's search order actually PREFERS that build, which is why an
# animation drew nothing and left a blank panel. So image work needs its own
# lookup, and it must verify by PERFORMING the operation rather than by trusting
# a path or a version string.
FBINK_IMG=""
FBINK_IMG_UNUSABLE=0
FBINK_IMAGE_CANDIDATES="${FBINK_IMAGE_CANDIDATES:-/mnt/us/libkh/bin/fbink /mnt/us/extensions/MRInstaller/bin/KHF/fbink /mnt/us/koreader/fbink /var/tmp/kdash/fbink}"

# Echoes the path of a binary that can actually draw images, or fails.
#
# CAUTION: this both echoes the path AND caches it in FBINK_IMG. Calling it as
# path=$(find_fbink_image f) runs the body in a SUBSHELL, so the cache is lost
# and the probe repeats on every call. Call it with output redirected instead:
#
#     find_fbink_image "$frame" >/dev/null || return 1   # then use $FBINK_IMG
#
find_fbink_image() {
    _probe="$1"
    if [ -n "$FBINK_IMG" ] && [ -x "$FBINK_IMG" ]; then
        printf '%s' "$FBINK_IMG"
        return 0
    fi
    # Do not re-probe every frame once we know the device cannot do this.
    [ "$FBINK_IMG_UNUSABLE" = "1" ] && return 1
    if [ -z "$_probe" ] || [ ! -f "$_probe" ]; then
        log "image: no probe frame, cannot verify image support"
        return 1
    fi
    # $FBINK first, so when it does support images we stay on one binary.
    for _c in "$FBINK" $FBINK_IMAGE_CANDIDATES; do
        [ -n "$_c" ] || continue
        [ -x "$_c" ] || continue
        # -b keeps the probe off the panel; only the exit status matters.
        if "$_c" -q -b -g "file=$_probe,x=0,y=0" >/dev/null 2>&1; then
            FBINK_IMG="$_c"
            log "image: $_c can draw images"
            printf '%s' "$FBINK_IMG"
            return 0
        fi
    done
    log "image: NO fbink here can draw images (checked: $FBINK $FBINK_IMAGE_CANDIDATES)"
    FBINK_IMG_UNUSABLE=1
    return 1
}

# ---------------------------------------------------------------------------
# fonts
# ---------------------------------------------------------------------------
# Returns the first readable font from "$1" (preferred) then a candidate list
# of "$2" (comma separated). Falls back to "" so callers can use bitmap fonts.
pick_font() {
    _pref="$1"; _alts="$2"
    if [ -n "$_pref" ] && [ -r "$_pref" ]; then printf '%s' "$_pref"; return 0; fi
    _oldIFS="$IFS"; IFS=','
    for _f in $_alts; do
        if [ -n "$_f" ] && [ -r "$_f" ]; then
            IFS="$_oldIFS"; printf '%s' "$_f"; return 0
        fi
    done
    IFS="$_oldIFS"
    printf ''
    return 1
}

# ---------------------------------------------------------------------------
# LIPC / power
# ---------------------------------------------------------------------------
lipc_get() {  # $1 = property, $2 = type flag (i|s|e), $3 = default
    _v=$(lipc-get-prop ${2:+-$2} com.lab126.powerd "$1" 2>/dev/null | tr -d '\r')
    if [ -z "$_v" ]; then printf '%s' "$3"; else printf '%s' "$_v"; fi
}

# Some firmwares implement preventScreenSaver, others preventSuspend/stayAwake.
# Try each, verify by reading back, and remember which one took.
POWER_PROP=""
POWER_PROP_ORIG=""
POWER_PROP_ORIG_VAL=""

set_power_prevent() {
    [ "${KEEP_AWAKE:-1}" = "1" ] || return 0
    if [ -n "$POWER_PROP" ]; then
        lipc-set-prop -i com.lab126.powerd "$POWER_PROP" 1 2>/dev/null
        return 0
    fi
    for p in preventScreenSaver preventSuspend stayAwake; do
        _orig=$(lipc-get-prop -i com.lab126.powerd "$p" 2>/dev/null | tr -d '\r')
        [ -n "$_orig" ] || continue
        if lipc-set-prop -i com.lab126.powerd "$p" 1 2>/dev/null; then
            _now=$(lipc-get-prop -i com.lab126.powerd "$p" 2>/dev/null | tr -d '\r')
            if [ "$_now" = "1" ]; then
                POWER_PROP="$p"
                POWER_PROP_ORIG="$p"
                POWER_PROP_ORIG_VAL="$_orig"
                log "power: $p=$_now (was $_orig)"
                return 0
            fi
        fi
    done
    log "power: WARNING no prevent* property accepted; the screensaver may appear"
    return 1
}

# Nudge powerd's inactivity timer so auto-suspend does not fire while we are
# the thing on screen. KOReader uses the same call on this device.
reset_idle_timer() {
    [ "${KEEP_AWAKE:-1}" = "1" ] || return 0
    lipc-set-prop -i com.lab126.powerd touchScreenSaverTimeout 1 2>/dev/null
    return 0
}

save_power_originals() {
    _f="$STATE_DIR/original-powerd.txt"
    [ -f "$_f" ] && return 0     # never overwrite a captured original
    {
        printf 'preventScreenSaver=%s\n' \
            "$(lipc-get-prop -i com.lab126.powerd preventScreenSaver 2>/dev/null | tr -d '\r')"
        printf 'preventSuspend=%s\n' \
            "$(lipc-get-prop -i com.lab126.powerd preventSuspend 2>/dev/null | tr -d '\r')"
        printf 'stayAwake=%s\n' \
            "$(lipc-get-prop -i com.lab126.powerd stayAwake 2>/dev/null | tr -d '\r')"
        printf 'flIntensity=%s\n' \
            "$(lipc-get-prop -i com.lab126.powerd flIntensity 2>/dev/null | tr -d '\r')"
        # flOn is not present on every model, so this line can legitimately be
        # empty; restore skips empty values.
        printf 'flOn=%s\n' \
            "$(lipc-get-prop -i com.lab126.powerd flOn 2>/dev/null | tr -d '\r')"
    } > "$_f" 2>/dev/null
    log "saved original powerd properties to $_f"
}

restore_power_originals() {
    _f="$STATE_DIR/original-powerd.txt"
    if [ "$POWER_PROP" = "stayAwake" ]; then
        lipc-set-prop -i com.lab126.powerd stayAwake 0 2>/dev/null
    fi
    [ -r "$_f" ] || return 0
    while IFS='=' read -r _k _v; do
        case "$_k" in
            preventScreenSaver|preventSuspend|stayAwake|flIntensity|flOn)
                [ -n "$_v" ] || continue
                lipc-set-prop -i com.lab126.powerd "$_k" "$_v" 2>/dev/null
                log "restored $_k=$_v"
                ;;
        esac
    done < "$_f"
    return 0
}

# Frontlight brightness 0-24, or -1 to leave the user's setting alone. The
# original value is captured by save_power_originals and restored on stop.
#
# 0 is the default: this is a standby display, meant to sit showing one page for
# days, and a lit frontlight is the single biggest drain on a device we are
# deliberately keeping awake. Note that 0 is NOT the same as -1 -- -1 really does
# leave the light at whatever the user last chose, which is how it can end up
# burning all night.
#
# Lives here rather than in dashboard.sh so it sits with the save/restore pair and
# can be exercised by the test suite.
apply_frontlight() {
    case "${FRONTLIGHT:--1}" in
        -1|'') return 0 ;;
    esac
    is_int "$FRONTLIGHT" || { log "power: FRONTLIGHT='$FRONTLIGHT' is not a number, ignoring"; return 0; }

    # flIntensity is the brightness, but some firmware clamps 0 back up, and some
    # gates the light behind flOn as well, so drive both. Either property may be
    # absent -- a failure here must never stop the dashboard.
    if [ "$FRONTLIGHT" -le 0 ]; then
        lipc-set-prop -i com.lab126.powerd flIntensity 0 2>/dev/null
        lipc-set-prop -i com.lab126.powerd flOn 0 2>/dev/null
    else
        lipc-set-prop -i com.lab126.powerd flOn 1 2>/dev/null
        lipc-set-prop -i com.lab126.powerd flIntensity "$FRONTLIGHT" 2>/dev/null
    fi

    # Read it back. Silently failing to turn the light off is invisible otherwise:
    # the frames render perfectly and the battery quietly drains.
    _got=$(lipc-get-prop -i com.lab126.powerd flIntensity 2>/dev/null | tr -d '\r')
    _on=$(lipc-get-prop -i com.lab126.powerd flOn 2>/dev/null | tr -d '\r')
    log "power: frontlight wanted=$FRONTLIGHT flIntensity=${_got:-?} flOn=${_on:-n/a}"
    if [ "$FRONTLIGHT" -le 0 ] && [ -n "$_got" ]; then
        case "$_got" in
            *[!0-9]*) : ;;
            0) : ;;
            *) log "power: WARNING the frontlight would not go to 0 (reports $_got)" ;;
        esac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# networking
# ---------------------------------------------------------------------------
CURL_BIN=""
WGET_BIN=""

find_http() {
    for c in /usr/bin/curl /usr/local/bin/curl /bin/curl; do
        [ -x "$c" ] && CURL_BIN="$c" && return 0
    done
    for c in /usr/bin/wget /usr/local/bin/wget /bin/wget; do
        [ -x "$c" ] && WGET_BIN="$c" && return 0
    done
    return 1
}

http_get() {  # $1 = url -> body on stdout
    if [ -n "$CURL_BIN" ]; then
        "$CURL_BIN" -fsSL --connect-timeout 10 --max-time 25 "$1" 2>>"$LOG_FILE"
    elif [ -n "$WGET_BIN" ]; then
        "$WGET_BIN" -q -O - -T 25 "$1" 2>>"$LOG_FILE"
    else
        return 1
    fi
}

http_date_header() {  # $1 = url -> "Thu, 02 Oct 2026 05:11:33 GMT"
    [ -n "$CURL_BIN" ] || return 1
    "$CURL_BIN" -fsSI --connect-timeout 8 --max-time 15 "$1" 2>/dev/null \
        | tr -d '\r' \
        | awk 'tolower($1)=="date:"{ $1=""; sub(/^[ \t]+/,""); print; exit }'
}

# ---------------------------------------------------------------------------
# fbink font capability probe
# ---------------------------------------------------------------------------
# Ask fbink whether it can really render with this font. The draw goes into the
# framebuffer only (never refreshed), so a failed probe stays invisible until
# the next real repaint.
probe_font() {
    [ -n "$1" ] || return 1
    [ -n "$FBINK" ] || return 1
    "$FBINK" -q -b -O -t "regular=$1,px=24,top=0,left=0,right=0" "x" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Touchscreen discovery (the escape hatch)
# ---------------------------------------------------------------------------
# /proc/bus/input/devices is a sequence of blank-line separated blocks:
#     N: Name="cyttsp5_mt"
#     H: Handlers=event2
# The Name line comes first in each block, so remember it and act on Handlers.
TOUCH_DEV_CACHE=""
TOUCH_DEV_PROBED=0

# Overridable so the parser can be tested off-device.
INPUT_DEVICES_FILE="${INPUT_DEVICES_FILE:-/proc/bus/input/devices}"

# Parse an /proc/bus/input/devices style file and print the touchscreen's
# /dev/input/eventN path. Kept separate from find_touch_device so it can be
# tested against a fixture without the device node existing.
#
# The file is a sequence of blank-line separated blocks, Name before Handlers:
#     N: Name="cyttsp5_mt"
#     H: Handlers=event2
parse_touch_device() {
    [ -r "$1" ] || return 1
    awk '
        /^N: Name=/ { name = tolower($0) }
        /^H: Handlers=/ {
            if (name ~ /touch|cyttsp|ft5x06|goodix|elan|synaptics|zforce|tpd/) {
                if (match($0, /event[0-9]+/)) {
                    print "/dev/input/" substr($0, RSTART, RLENGTH)
                    exit
                }
            }
        }
    ' "$1" 2>/dev/null | head -n 1
}

find_touch_device() {
    if [ "$TOUCH_DEV_PROBED" = "1" ]; then
        [ -n "$TOUCH_DEV_CACHE" ] || return 1
        printf '%s' "$TOUCH_DEV_CACHE"
        return 0
    fi
    TOUCH_DEV_PROBED=1

    # Searching one line per block, so `|| return 1` earns its keep: without it
    # an empty result would be cached as "no touchscreen" for the whole session.
    _found=$(parse_touch_device "$INPUT_DEVICES_FILE") || _found=""
    [ -n "$_found" ] && [ -r "$_found" ] || return 1

    TOUCH_DEV_CACHE="$_found"
    printf '%s' "$_found"
    return 0
}

# Decode a raw input_event into "type code value".
#
# 32-bit Linux layout, 16 bytes little-endian:
#   [0..3] tv_sec  [4..7] tv_usec  [8..9] type  [10..11] code  [12..15] value
# `od -An -tu1` prints those as whitespace separated shell arguments.
#
# NOTE: positional parameters above 9 MUST be braced. `$10` is not the tenth
# argument, it is `${1}` followed by a literal `0` -- which silently turned
# BTN_TOUCH (330) into 513 here and would have disabled the escape hatch.
# Watch for EV_KEY(1) / BTN_TOUCH(330) / value 1.
decode_evdev_event() {
    set -- $1
    [ $# -ge 16 ] || return 1
    printf '%s %s %s\n' \
        "$(( $9 + 256 * ${10} ))" \
        "$(( ${11} + 256 * ${12} ))" \
        "$(( ${13} + 256 * ${14} ))"
}

# True only if we can actually detect a tap: a touch device AND od to decode
# the raw input_event structs.
escape_available() {
    find_touch_device >/dev/null 2>&1 || return 1
    command -v od >/dev/null 2>&1 || return 1
    return 0
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------
round0() {  # round a decimal string to the nearest integer
    printf '%s' "$1" | awk '{ if ($1 ~ /^-?[0-9.]+$/) printf "%d", ($1 < 0 ? $1 - 0.5 : $1 + 0.5); else printf "?" }'
}

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Animation frame naming, in ONE place because both the player (anim.sh) and the
# artwork fetcher (update.sh) have to agree on it. Zero-padded to three digits so
# a plain shell glob lists them in order. See artwork/FORMAT.md.
ANIM_FRAME_GLOB="frame_*.png"
ANIM_MANIFEST="manifest.json"

# Sleep for a number of milliseconds.
#
# busybox sleep only takes whole seconds, and usleep is not reliably discoverable
# with command -v from a KUAL environment even though KOReader calls it directly.
# So probe by RUNNING it. Getting this wrong is not cosmetic: falling back to
# whole-second sleeps silently turns an 8fps animation into a 1fps one, which is
# exactly what happened on hardware.
SLEEP_MS_CMD=""
SLEEP_MS_PROBED=0

sleep_ms() {
    _ms="$1"
    is_int "$_ms" || _ms=100
    [ "$_ms" -lt 1 ] && _ms=1

    if [ "$SLEEP_MS_PROBED" = "0" ]; then
        SLEEP_MS_PROBED=1
        # Several ways to sleep for less than a second, tried in order by
        # actually running each. usleep is what KOReader uses, but it is not
        # always on PATH, and some busybox builds accept a decimal for sleep.
        if usleep 1000 >/dev/null 2>&1; then
            SLEEP_MS_CMD="usleep"
        elif busybox usleep 1000 >/dev/null 2>&1; then
            SLEEP_MS_CMD="busybox usleep"
        elif /usr/bin/usleep 1000 >/dev/null 2>&1; then
            SLEEP_MS_CMD="/usr/bin/usleep"
        elif sleep 0.001 >/dev/null 2>&1; then
            SLEEP_MS_CMD="float"
        else
            SLEEP_MS_CMD="sleep"
            log "sleep: no sub-second sleep available; using whole seconds (animation will be slow)"
        fi
        log "sleep: using '$SLEEP_MS_CMD'"
    fi

    case "$SLEEP_MS_CMD" in
        float)
            sleep "$(printf '%d.%03d' $(( _ms / 1000 )) $(( _ms % 1000 )))"
            ;;
        sleep)
            # Round up so a request is never shortened below what was asked for.
            sleep "$(( ( _ms + 999 ) / 1000 ))"
            ;;
        *)
            # usleep takes microseconds. Unquoted on purpose: the value may be
            # two words, e.g. "busybox usleep".
            $SLEEP_MS_CMD "$(( _ms * 1000 ))"
            ;;
    esac
    return 0
}
