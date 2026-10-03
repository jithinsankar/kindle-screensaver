#!/bin/sh
# ============================================================================
#  Rendering -- an iOS-style lockscreen, drawn with fbink
#
#  Layout (600x800):
#
#      Thursday, 2 October          <- date, muted, small
#              10:42                <- clock, very large
#      +---------------------------+
#      |        Bengaluru          |  <- light grey "widget" panel
#      |           27°             |
#      |    <icon> Clear · 31°/22° |
#      +---------------------------+
#      +---------------------------+
#      |        Thalassery         |
#      |           29°             |
#      |   <icon> Rain · 32°/25°   |
#      +---------------------------+
#              Updated 10:41        <- faint footer
#
#  fbink's OpenType renderer places the first baseline at (top + ascent), so
#  the visible ink of a line starts roughly 0.36em below the value passed in
#  `top`. The *_TOP defaults in config.sh already account for that.
# ============================================================================

# --- primitives ------------------------------------------------------------
# Geometry that render_full computes from fbink's measurements, then
# render_clock_only reuses on every subsequent minute tick.
CLOCK_TOP_ACTUAL=""
CLOCK_BAND_TOP="${CLOCK_BAND_TOP:-60}"
CLOCK_BAND_HEIGHT="${CLOCK_BAND_HEIGHT:-280}"
LAST_DATE=""
# Set by draw_line on every call.
DRAW_NEXT_TOP=""
DRAW_BBOX_H=""

# In batch mode we update the framebuffer without refreshing the panel, then do
# a single full refresh at the end. With BATCH_DRAWS=0 every call refreshes.
fb_batch() {
    if [ "${BATCH_DRAWS:-1}" = "1" ]; then
        "$FBINK" -q -b "$@"
    else
        "$FBINK" -q "$@"
    fi
}
fb_now() { "$FBINK" -q "$@"; }

draw_panel() {  # $1=top $2=left $3=width $4=height $5=colour
    "$FBINK" -q -b -k "top=$1,left=$2,width=$3,height=$4" -B "$5" 2>>"$LOG_FILE"
}

# draw_line <font> <px> <colour> <top> <left> <right> <text> <batch|now> <bgless>
# Centred horizontally inside [left,right].
#
# bgless=1 leaves the background pixels alone so a panel fill shows through.
# bgless=0 paints the background instead. Both are needed: digits are tabular
# (verified in NotoSans and NotoSansCJKsc, all 0.572em) so a clock's bounding box
# never changes width, but an opaque draw is what actually erases the previous
# digits -- while a huge bgless glyph is what lets the clock sit near the date
# without its line box painting over it.
#
# After the call, DRAW_NEXT_TOP holds the `top` fbink recommends for the next
# line, and DRAW_BBOX_H the measured ink height. Both are empty if fbink could
# not report them, in which case callers fall back to an estimate.
draw_line() {
    _font="$1"; _px="$2"; _col="$3"; _top="$4"; _left="$5"; _right="$6"
    _txt="$7"; _mode="$8"; _bgless="${9:-0}"
    DRAW_NEXT_TOP=""
    DRAW_BBOX_H=""
    [ -n "$_txt" ] || return 0

    if [ -n "$_font" ]; then
        _rc=1
        if [ "${MEASURE_LAYOUT:-1}" = "1" ]; then
            _out=$(_fbink_ot 1 "$_font" "$_px" "$_col" "$_top" "$_left" \
                             "$_right" "$_txt" "$_mode" "$_bgless")
            _rc=$?
        fi
        if [ "$_rc" -eq 0 ]; then
            parse_measure "$_out"
            return 0
        fi
        # Retry without -E before giving up on OpenType: on some builds -E may
        # not combine with the other options, and silently dropping to the
        # bitmap font would wreck the whole layout.
        if _fbink_ot 0 "$_font" "$_px" "$_col" "$_top" "$_left" \
                     "$_right" "$_txt" "$_mode" "$_bgless"; then
            return 0
        fi
        log "render: OpenType failed for '$_txt', using bitmap font"
    fi

    _row=$(( _top > 0 ? _top / 28 : 0 ))
    if [ "$_mode" = "now" ]; then
        "$FBINK" -q -m -y "$_row" "$_txt" 2>>"$LOG_FILE"
    else
        "$FBINK" -q -b -m -y "$_row" "$_txt" 2>>"$LOG_FILE"
    fi
}

# One place that builds the fbink OpenType invocation, so the measurement flag
# can be dropped and the draw retried without duplicating the argument list.
# $1 = 1 to add -E, then font px colour top left right text mode bgless
_fbink_ot() {
    _want_e="$1"; shift
    _font="$1"; _px="$2"; _col="$3"; _top="$4"; _left="$5"; _right="$6"
    _txt="$7"; _mode="$8"; _bgless="${9:-0}"
    _spec="regular=$_font,px=$_px,top=$_top,left=$_left,right=$_right"
    _flags="-q -m"
    [ "$_mode" = "now" ] || _flags="$_flags -b"
    if [ "$_bgless" = "1" ]; then
        _flags="$_flags -O"
    else
        _flags="$_flags -B ${C_BG:-WHITE}"
    fi
    [ "$_want_e" = "1" ] && _flags="$_flags -E"
    # Word splitting of _flags is intended; every value is a bare token.
    "$FBINK" $_flags -C "$_col" -t "$_spec" "$_txt" 2>>"$LOG_FILE"
}

# fbink -E prints, on the OpenType path:
#   next_top=N;computed_lines=N;rendered_lines=N;bbox_width=N;bbox_height=N;truncated=d;
parse_measure() {
    DRAW_NEXT_TOP=$(printf '%s' "$1" | sed -n 's/.*next_top=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    DRAW_BBOX_H=$(printf '%s' "$1" | sed -n 's/.*bbox_height=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    # next_top=0 is fbink's "no room left" sentinel, not a real position.
    [ "$DRAW_NEXT_TOP" = "0" ] && DRAW_NEXT_TOP=""
    is_int "$DRAW_NEXT_TOP" || DRAW_NEXT_TOP=""
    return 0
}

# Where the next block starts. Uses fbink's own measurement when we have it and
# a conservative line-height estimate when we do not, so stacking never depends
# on knowing where ink sits inside a line box.
# $1 = this block's top, $2 = its px, $3 = its measured next_top
next_top_from() {
    if is_int "$3" && [ "$3" != "0" ]; then
        printf '%s' "$3"
        return 0
    fi
    # Round rather than truncate: under-estimating a line advance would let the
    # next block creep up into this one, which is the failure we are fixing.
    printf '%s' "$(printf '%s' "$2" | awk -v t="$1" -v f="${FALLBACK_LINE_FACTOR:-1.45}" \
        '{ printf "%d", t + int($1 * f + 0.5) }')"
}

# --- pieces ----------------------------------------------------------------
date_line() {
    _dow=$(date +%A)
    _mon=$(date +%B)
    _day=$(date +%d)
    _day=${_day#0}
    printf '%s, %s %s' "$_dow" "$_day" "$_mon"
}

draw_date_at() {  # $1 = top, $2 = batch|now
    [ "${SHOW_DATE:-1}" = "1" ] || return 0
    draw_line "$FONT_TEXT_RESOLVED" "${DATE_PX:-24}" "$C_MUTED" \
              "$1" 20 20 "$(date_line)" "$2" 0
}

# The clock is drawn WITHOUT a background (bgless). fbink paints the background
# over the whole LINE BOX, and a 200px font has a ~272px line box, so an opaque
# clock would wipe the date sitting above it. Ghosting is handled by wiping a
# band first (clock_band_reset), whose top is derived from the date's MEASURED
# bottom rather than from an estimate.
draw_clock_at() {  # $1 = top, $2 = batch|now
    CLOCK_TOP_ACTUAL="$1"
    draw_line "$FONT_TEXT_RESOLVED" "${CLOCK_PX:-200}" "$C_CLOCK" \
              "$1" 20 20 "$(date +%H:%M)" "$2" 1
}

# Wipe the clock band. In batch mode this only touches the framebuffer, and the
# caller finishes with a single regional refresh.
clock_band_reset() {
    _rect="top=${CLOCK_BAND_TOP:-62},left=0,width=600,height=${CLOCK_BAND_HEIGHT:-170}"
    if [ "${BATCH_DRAWS:-1}" = "1" ]; then
        "$FBINK" -q -b -k "$_rect" -B "${C_BG:-WHITE}" 2>>"$LOG_FILE"
    else
        "$FBINK" -q -k "$_rect" -B "${C_BG:-WHITE}" 2>>"$LOG_FILE"
    fi
}

# Refresh just that band. Combined with clock_band_reset + a bgless draw this
# costs a single eInk update, so the band never visibly blanks.
clock_band_refresh() {
    "$FBINK" -q -s \
        "top=${CLOCK_BAND_TOP:-62},left=0,width=600,height=${CLOCK_BAND_HEIGHT:-170}" \
        2>>"$LOG_FILE"
}

draw_card() {  # $1 = index  $2 = panel top
    _i="$1"; _top="$2"
    weather_load "$_i" || return 0

    _left="${CARD_LEFT:-40}"
    _w="${CARD_WIDTH:-520}"
    _h="${CARD_HEIGHT:-152}"
    draw_panel "$_top" "$_left" "$_w" "$_h" "$C_PANEL"

    # fbink's left=/right= are margins from the screen edges, NOT coordinates.
    # The panel occupies [_left, _left + _width]; to keep the text inside it
    # with 12px of padding, the margin on BOTH sides is _left + 12. Passing a
    # coordinate for `right` gives a zero-width area, fbink fails, and every
    # line silently falls back to the bitmap font in the wrong place.
    _mx=$(( _left + 12 ))
    _il="$_mx"
    _ir="$_mx"

    # Chain the three lines so the condition line can never drift off the
    # bottom edge of the panel: each one is placed from the measured advance of
    # the one above it.
    _y=$(( _top + ${CARD_PAD_TOP:-12} ))
    draw_line "$FONT_CARD_RESOLVED" "${CARD_LABEL_PX:-22}" "$C_MUTED" \
              "$_y" "$_il" "$_ir" "$WX_LABEL" batch 1
    _y=$(next_top_from "$_y" "${CARD_LABEL_PX:-22}" "$DRAW_NEXT_TOP")
    _y=$(( _y + ${CARD_GAP1:-6} ))

    draw_line "$FONT_CARD_RESOLVED" "${CARD_TEMP_PX:-52}" "$C_PRIMARY" \
              "$_y" "$_il" "$_ir" "${WX_TEMP}°" batch 1
    _y=$(next_top_from "$_y" "${CARD_TEMP_PX:-52}" "$DRAW_NEXT_TOP")
    _y=$(( _y + ${CARD_GAP2:-4} ))

    _cond="$WX_TEXT"
    if [ -n "$WX_TMAX" ] && [ -n "$WX_TMIN" ]; then
        _cond="$WX_TEXT · ${WX_TMAX}°/${WX_TMIN}°"
    fi
    if [ "${SHOW_ICONS:-1}" = "1" ] && [ -n "$WX_ICON" ]; then
        _cond="$WX_ICON $_cond"
    fi

    draw_line "$FONT_CARD_RESOLVED" "${CARD_COND_PX:-22}" "$C_MUTED" \
              "$_y" "$_il" "$_ir" "$_cond" batch 1
}

draw_footer() {  # $1 = batch|now
    [ "${SHOW_FOOTER:-1}" = "1" ] || return 0
    # Deliberately the time of the last weather fetch, not the current time:
    # that way the footer only changes on a full repaint and does not cost a
    # refresh every single minute.
    _t=$(weather_fetch_time 2>/dev/null)
    [ -n "$_t" ] || _t=$(date +%H:%M)
    draw_line "$FONT_TEXT_RESOLVED" "${FOOTER_PX:-22}" "$C_FAINT" \
              "${FOOTER_TOP:-750}" 20 20 "Updated $_t" "$1" 0
}

# --- composition -----------------------------------------------------------
# Full repaint: clear once, draw everything into the framebuffer without
# refreshing, then flush the eInk panel in a single update (no flicker between
# elements). A periodic black flash clears accumulated ghosting.
REFRESH_COUNT=0

render_full() {
    [ -n "$FBINK" ] || return 1
    REFRESH_COUNT=$(( REFRESH_COUNT + 1 ))

    fb_batch -c -B "${C_BG:-WHITE}"

    # --- date, then the clock stacked directly beneath it ------------------
    # Both come from fbink's own reported line advance. Chaining, rather than
    # placing each at an independently guessed offset, is what guarantees they
    # cannot overlap whatever the real font metrics turn out to be.
    _y="${DATE_TOP:-20}"
    draw_date_at "$_y" batch
    _y=$(next_top_from "$_y" "${DATE_PX:-24}" "$DRAW_NEXT_TOP")
    _date_bottom="$_y"

    _y=$(( _y + ${CLOCK_GAP:-6} ))
    CLOCK_BAND_TOP=$(( _date_bottom + 2 ))
    draw_clock_at "$_y" batch
    _clock_bottom=$(next_top_from "$_y" "${CLOCK_PX:-200}" "$DRAW_NEXT_TOP")

    # The band covers the clock's ink, bounded by its measured line advance, and
    # is capped so it can never reach the cards.
    _bh=$(( _clock_bottom - CLOCK_BAND_TOP + 4 ))
    _max=$(( ${CARD1_TOP:-370} - CLOCK_BAND_TOP - 10 ))
    [ "$_bh" -gt "$_max" ] && _bh="$_max"
    [ "$_bh" -lt 40 ] && _bh=40
    CLOCK_BAND_HEIGHT="$_bh"

    # --- cards, anchored from the bottom so the footer always fits ---------
    _idx=0
    for _t in "${CARD1_TOP:-370}" "${CARD2_TOP:-562}"; do
        draw_card "$_idx" "$_t"
        _idx=$(( _idx + 1 ))
    done

    draw_footer batch

    # Remember the date we just painted so render_clock_only can spot the
    # midnight rollover without a redundant repaint on the first tick.
    LAST_DATE=$(date_line)

    [ "${BATCH_DRAWS:-1}" = "1" ] || return 0
    if [ "$(( REFRESH_COUNT % ${FLASH_EVERY:-10} ))" -eq 0 ]; then
        fb_now -s -f 2>>"$LOG_FILE"
    else
        fb_now -s 2>>"$LOG_FILE"
    fi
    return 0
}

# Just the clock. Since the clock is drawn bgless, ghosting is handled by
# wiping its band first: the wipe and the draw both write to the framebuffer
# without refreshing, then one regional refresh paints the finished result. The
# band starts below the date's ink, so the date is never disturbed and never
# has to be redrawn.
LAST_DATE=""

render_clock_only() {
    [ -n "$FBINK" ] || return 1

    # Midnight rollover: patch the whole screen rather than juggling bands.
    _d=$(date_line)
    if [ "$_d" != "$LAST_DATE" ]; then
        log "clock: date changed to '$_d', full repaint"
        render_full
        return 0
    fi

    clock_band_reset
    draw_clock_at "${CLOCK_TOP_ACTUAL:-60}" batch
    [ "${BATCH_DRAWS:-1}" = "1" ] && clock_band_refresh
    return 0
}
