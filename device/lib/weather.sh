#!/bin/sh
# ============================================================================
#  kindle-weather -- fetch today's weather with nothing but a POSIX shell
#
#  Downloads the current conditions and today's high/low from a keyless HTTP
#  API and caches them as ONE line of pipe-separated text. That single line is
#  the whole point of the design: a Kindle has no jq, no Python and no JSON
#  library, and one line is trivial for any shell to read back.
#
#  Primary : open-meteo.com  (no API key, compact JSON, 15-min resolution)
#  Fallback: wttr.in         (plain text; no high/low, no weather code)
#
#  Nothing here is device-specific. It needs a POSIX shell and curl or wget,
#  and runs the same on a Kindle, a laptop, a router or a Raspberry Pi.
#
#  Usage:
#      . ./weather.sh
#      weather_fetch 0 "Home" 12.97 77.59 Asia/Kolkata   # download + cache
#      weather_load  0                                   # -> WX_* variables
#      printf '%s\n' "$WX_TEMP $WX_TEXT $WX_ICON"
#
#  Cache file format, one line, pipe separated:
#     epoch|temp|feels|humidity|code|tmax|tmin|text|icon|label|fetchtime
#
#  ---------------------------------------------------------------------------
#  Host contract
#
#  The module is self-contained: source it and it works. But if the host has
#  already defined any of the helpers below, the host's version wins, so an
#  embedding application keeps its own HTTP stack and its own logging. That is
#  how the Kindle dashboard embeds it -- it sources its util.sh first, so its
#  log() and its cached curl discovery stay in charge, and the identical
#  fallbacks in this file are skipped.
#
#      log       log a line (fallback: silently discard)
#      http_get  GET a url, body on stdout (fallback: curl, then wget)
#      is_int    test a string is non-negative integer (fallback: provided)
#      round0    round a decimal string (fallback: provided)
#      json_section / json_num / json_str (fallback: provided)
#
#  WX_CACHE_DIR selects where the one-line cache lives. Nothing else in this
#  file reads a variable it did not define itself.
# ============================================================================

# --- cache location --------------------------------------------------------
# The host normally points this at its own state directory. On its own the
# module just needs somewhere writable, because a weather fetch that cannot
# cache is pointless -- the cache is what keeps a 15-minute refresh cheap.
WX_CACHE_DIR="${WX_CACHE_DIR:-${TMPDIR:-/tmp}/kindle-weather}"

# --- host hooks (only defined when the host did not) -----------------------
# `command -v` sees shell functions as well as binaries, in every POSIX shell
# this has been run under (busybox ash, dash, bash, mksh).
#
# EVERY hook is guarded, not just the first. Guarding some and not others is
# worse than guarding none: the embedding application would keep its logging
# while silently losing its HTTP stack, which only shows up on a device where
# the cached curl lookup actually mattered.
command -v log >/dev/null 2>&1 || log() { return 0; }

command -v is_int >/dev/null 2>&1 || is_int() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# round a decimal string to the nearest integer
command -v round0 >/dev/null 2>&1 || round0() {
    printf '%s' "$1" | awk '{ if ($1 ~ /^-?[0-9.]+$/) printf "%d", ($1 < 0 ? $1 - 0.5 : $1 + 0.5); else printf "?" }'
}

# $1 = url -> body on stdout
command -v http_get >/dev/null 2>&1 || http_get() {
    if [ -n "${CURL_BIN:-}" ]; then
        "$CURL_BIN" -fsSL --connect-timeout 10 --max-time 25 "$1" 2>>"${LOG_FILE:-/dev/null}"
        return $?
    fi
    if [ -n "${WGET_BIN:-}" ]; then
        "$WGET_BIN" -q -O - -T 25 "$1" 2>>"${LOG_FILE:-/dev/null}"
        return $?
    fi
    # No cached discovery from the host, so look for ourselves.
    for _c in /usr/bin/curl /usr/local/bin/curl /bin/curl; do
        [ -x "$_c" ] || continue
        CURL_BIN="$_c"
        "$_c" -fsSL --connect-timeout 10 --max-time 25 "$1" 2>>"${LOG_FILE:-/dev/null}"
        return $?
    done
    for _w in /usr/bin/wget /usr/local/bin/wget /bin/wget; do
        [ -x "$_w" ] || continue
        WGET_BIN="$_w"
        "$_w" -q -O - -T 25 "$1" 2>>"${LOG_FILE:-/dev/null}"
        return $?
    done
    return 1
}

# --- tiny JSON helpers -----------------------------------------------------
# sed only. There is no jq on a Kindle and this is not worth an awk program.
#
# All three tolerate whitespace between a colon and its value, because
# pretty-printed JSON is a normal thing for a proxy or a test fixture to hand
# back -- and every field silently returning nothing is a miserable bug to
# track down. Callers must flatten newlines first (tr -d '\n').
# $1=json $2=key -> contents of "key":{ ... }
command -v json_section >/dev/null 2>&1 || json_section() {
    # Built in a variable rather than inline: the quoting needed to interpolate
    # a key into a sed script is easy to get wrong inline.
    _pat='s/.*"'"$2"'":[[:space:]]*{//p'
    printf '%s' "$1" | sed -n "$_pat" | sed 's/}.*//'
}

# $1=blob $2=key -> first number, scalar or a one-element array
command -v json_num >/dev/null 2>&1 || json_num() {
    # NOTE: both the opening and closing brackets must be optional here.
    # Open-Meteo returns bare scalars in "current" but arrays in "daily", so a
    # mandatory \] quietly matched only the arrays and returned nothing for
    # every scalar.
    _pat='s/.*"'"$2"'":[[:space:]]*\[*\(-\{0,1\}[0-9][0-9.]*\)\]*.*/\1/p'
    printf '%s' "$1" | sed -n "$_pat"
}

# $1=blob $2=key -> first string value
command -v json_str >/dev/null 2>&1 || json_str() {
    _pat='s/.*"'"$2"'":[[:space:]]*"\([^"]*\)".*/\1/p'
    printf '%s' "$1" | sed -n "$_pat"
}

# --- WMO weather code -> words and glyph -----------------------------------
# https://open-meteo.com/en/docs -- WMO 4677 present-weather codes.
wmo_text() {
    case "$1" in
        0)          printf 'Clear' ;;
        1)          printf 'Mainly clear' ;;
        2)          printf 'Partly cloudy' ;;
        3)          printf 'Overcast' ;;
        45|48)      printf 'Fog' ;;
        51)         printf 'Light drizzle' ;;
        53)         printf 'Drizzle' ;;
        55)         printf 'Heavy drizzle' ;;
        56|57)      printf 'Freezing drizzle' ;;
        61)         printf 'Light rain' ;;
        63)         printf 'Rain' ;;
        65)         printf 'Heavy rain' ;;
        66|67)      printf 'Freezing rain' ;;
        71)         printf 'Light snow' ;;
        73)         printf 'Snow' ;;
        75)         printf 'Heavy snow' ;;
        77)         printf 'Snow grains' ;;
        80)         printf 'Light showers' ;;
        81)         printf 'Showers' ;;
        82)         printf 'Heavy showers' ;;
        85|86)      printf 'Snow showers' ;;
        95)         printf 'Thunderstorm' ;;
        96|99)      printf 'Thunderstorm, hail' ;;
        *)          printf 'Unknown' ;;
    esac
}

# Three glyphs only, and they are chosen to exist in the fonts an e-reader
# actually ships. On the Kindle these were verified present in
# NotoSansCJKsc-Regular.otf: U+2600 U+2601 U+2602. Anything fancier renders as
# a hollow box, which looks like a bug rather than a cloud.
#   \342\230\200 = sun    \342\230\201 = cloud    \342\230\202 = umbrella
wmo_icon() {
    case "$1" in
        0|1)                  printf '\342\230\200' ;;
        2|3|45|48)            printf '\342\230\201' ;;
        51|53|55|56|57)       printf '\342\230\202' ;;
        61|63|65|66|67)       printf '\342\230\202' ;;
        71|73|75|77|85|86)    printf '\342\230\201' ;;
        80|81|82)             printf '\342\230\202' ;;
        95|96|99)             printf '\342\230\202' ;;
        *)                    printf '' ;;
    esac
}

# Same three glyphs, chosen from a wttr.in condition string, which is prose
# rather than a code.
text_icon() {
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
        *thunder*|*storm*)                printf '\342\230\202' ;;
        *drizzle*|*rain*|*shower*|*sleet*) printf '\342\230\202' ;;
        *snow*|*blizzard*)                printf '\342\230\201' ;;
        *fog*|*mist*|*haze*)              printf '\342\230\201' ;;
        *overcast*|*cloud*)               printf '\342\230\201' ;;
        *sunny*|*clear*)                  printf '\342\230\200' ;;
        *)                                printf '' ;;
    esac
}

# --- providers -------------------------------------------------------------
weather_openmeteo() {  # $1=lat $2=lon $3=tz $4=label -> cache line on stdout
    _url="https://api.open-meteo.com/v1/forecast"
    _url="${_url}?latitude=$1&longitude=$2"
    _url="${_url}&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code"
    _url="${_url}&daily=temperature_2m_max,temperature_2m_min"
    _url="${_url}&timezone=$3&forecast_days=1"

    _json=$(http_get "$_url") || return 1
    [ -n "$_json" ] || return 1
    case "$_json" in *'"current"'*) ;; *) return 1 ;; esac

    _cur=$(json_section "$_json" current)
    _day=$(json_section "$_json" daily)
    [ -n "$_cur" ] || return 1

    _temp=$(json_num "$_cur" temperature_2m)
    _code=$(json_num "$_cur" weather_code)
    _feels=$(json_num "$_cur" apparent_temperature)
    _hum=$(json_num "$_cur" relative_humidity_2m)
    _tmax=$(json_num "$_day" temperature_2m_max)
    _tmin=$(json_num "$_day" temperature_2m_min)

    [ -n "$_temp" ] || return 1
    is_int "$_code" || _code=0

    # Round up front, then blank anything the parser could not find so a missing
    # daily block cannot render as "31°/?°".
    _r_temp=$(round0 "$_temp")
    _r_feels=$(round0 "$_feels")
    _r_hum=$(round0 "$_hum")
    _r_tmax=$(round0 "$_tmax")
    _r_tmin=$(round0 "$_tmin")
    case "$_r_tmax" in ''|'?') _r_tmax="" ;; esac
    case "$_r_tmin" in ''|'?') _r_tmin="" ;; esac
    case "$_r_feels" in '?') _r_feels="" ;; esac
    case "$_r_hum" in '?') _r_hum="" ;; esac

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$(date +%s)" "$_r_temp" "$_r_feels" "$_r_hum" "$_code" \
        "$_r_tmax" "$_r_tmin" "$(wmo_text "$_code")" "$(wmo_icon "$_code")" \
        "$4" "$(date +%H:%M)"
}

weather_wttr() {  # $1=lat $2=lon $3=tz $4=label -> cache line on stdout
    # %t temp, %f feels-like, %C condition text, %h humidity. There is no
    # high/low in this format, hence the empty tmax/tmin fields.
    _txt=$(http_get "https://wttr.in/$1,$2?format=%t|%f|%C|%h") || return 1
    [ -n "$_txt" ] || return 1
    case "$_txt" in *'|'*'|'*) ;; *) return 1 ;; esac

    _oldIFS="$IFS"; IFS='|'
    set -- $_txt
    IFS="$_oldIFS"
    [ $# -ge 4 ] || return 1

    # Strip the unit suffixes ("27°C" -> "27").
    _t=$(printf '%s' "$1" | sed 's/[^0-9.+-]//g')
    _f=$(printf '%s' "$2" | sed 's/[^0-9.+-]//g')
    _c=$(printf '%s' "$3" | sed 's/^ *//; s/ *$//')
    _h=$(printf '%s' "$4" | sed 's/[^0-9]//g')
    [ -n "$_t" ] || return 1

    _r_t=$(round0 "$_t")
    _r_f=$(round0 "$_f")
    _r_h=$(round0 "$_h")
    case "$_r_f" in ''|'?') _r_f="" ;; esac
    case "$_r_h" in ''|'?') _r_h="" ;; esac

    printf '%s|%s|%s|%s|%s|||%s|%s|%s|%s\n' \
        "$(date +%s)" "$_r_t" "$_r_f" "$_r_h" \
        0 "$_c" "$(text_icon "$_c")" "$5" "$(date +%H:%M)"
}

# --- unit conversion -------------------------------------------------------
# Rounds rather than truncates: 27C must become 81F, not 80F.
convert_units() {  # $1 = a numeric temperature in Celsius
    [ "${UNITS:-celsius}" = "fahrenheit" ] || { printf '%s' "$1"; return 0; }
    printf '%s' "$1" | awk '{ v = ($1 * 9 / 5) + 32; printf "%d", (v < 0 ? v - 0.5 : v + 0.5) }'
}

# --- public API ------------------------------------------------------------
# weather_fetch <index> <label> <lat> <lon> <tz>
# Writes the cache file and echoes the cache line. Returns non-zero on failure,
# in which case the previous cache is left untouched.
weather_fetch() {
    _idx="$1"; _label="$2"; _lat="$3"; _lon="$4"; _tz="$5"
    _out=""

    if _out=$(weather_openmeteo "$_lat" "$_lon" "$_tz" "$_label" 2>>"${LOG_FILE:-/dev/null}"); then
        log "wx[$_idx] open-meteo ok: $_out"
    elif _out=$(weather_wttr "$_lat" "$_lon" "$_tz" "$_label" 2>>"${LOG_FILE:-/dev/null}"); then
        log "wx[$_idx] wttr.in ok: $_out"
    else
        log "wx[$_idx] both providers failed"
        return 1
    fi

    # Unit conversion on temp|feels|tmax|tmin (fields 2,3,6,7)
    if [ "${UNITS:-celsius}" = "fahrenheit" ]; then
        _oldIFS="$IFS"; IFS='|'
        set -- $_out
        IFS="$_oldIFS"
        _out="$1|$(convert_units "$2")|$(convert_units "$3")|$4|$5|$(convert_units "$6")|$(convert_units "$7")|$8|$9|${10}|${11}"
    fi

    # Only write on success, so a failed refresh cannot blank a good reading.
    mkdir -p "$WX_CACHE_DIR" 2>/dev/null
    printf '%s\n' "$_out" > "$WX_CACHE_DIR/wx$_idx.txt" 2>/dev/null
    LAST_WX_LINE="$_out"
    return 0
}

# weather_load <index> -> sets WX_* variables, returns 1 if no cache
weather_load() {
    _f="$WX_CACHE_DIR/wx$1.txt"
    [ -r "$_f" ] || return 1
    IFS='|' read -r WX_EPOCH WX_TEMP WX_FEELS WX_HUM WX_CODE WX_TMAX WX_TMIN \
                   WX_TEXT WX_ICON WX_LABEL WX_FETCH_HHMM < "$_f"
    [ -n "$WX_TEMP" ] || return 1
    return 0
}

# Time of the most recent successful fetch for location 0. For a footer such as
# "updated 14:35" -- deliberately the fetch time, not the current time, so a
# stale reading is visible as stale.
weather_fetch_time() {
    [ -r "$WX_CACHE_DIR/wx0.txt" ] || return 1
    cut -d'|' -f11 "$WX_CACHE_DIR/wx0.txt" 2>/dev/null
}
