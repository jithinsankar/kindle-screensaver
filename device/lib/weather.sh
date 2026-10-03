#!/bin/sh
# ============================================================================
#  Weather download + parse
#
#  Primary : open-meteo.com  (no API key, compact JSON, 15-min resolution)
#  Fallback: wttr.in        (plain text, no hi/lo)
#
#  Cache file format, one line, pipe separated:
#     epoch|temp|feels|humidity|code|tmax|tmin|text|icon|label|fetchtime
# ============================================================================

# --- tiny JSON helpers (busybox sed only, no jq on a Kindle) ---------------
json_section() {  # $1=json $2=key -> contents of "key":{ ... }
    # Tolerates whitespace between the colon and the brace: PowerShell's
    # ConvertTo-Json writes `"frame":  {`, and the artwork manifest is produced
    # by that tool. Callers must flatten newlines first (tr -d '\n').
    # Built in a variable rather than inline: the quoting needed to interpolate
    # a key into a sed script is easy to get wrong inline.
    _pat='s/.*"'"$2"'":[[:space:]]*{//p'
    printf '%s' "$1" | sed -n "$_pat" | sed 's/}.*//'
}

json_num() {  # $1=blob $2=key -> first number, scalar or a one-element array
    # NOTE: both the opening and closing brackets must be optional here.
    # Open-Meteo returns bare scalars in "current" but arrays in "daily",
    # and a mandatory \] silently matched only the arrays.
    # Also tolerates whitespace after the colon, because the artwork manifest is
    # written by ConvertTo-Json as `"x":  90` -- without this it returns nothing
    # for every field, silently.
    _pat='s/.*"'"$2"'":[[:space:]]*\[*\(-\{0,1\}[0-9][0-9.]*\)\]*.*/\1/p'
    printf '%s' "$1" | sed -n "$_pat"
}

json_str() {  # $1=blob $2=key -> first string value
    # Same whitespace tolerance as json_num: ConvertTo-Json writes `"active":  "x"`.
    _pat='s/.*"'"$2"'":[[:space:]]*"\([^"]*\)".*/\1/p'
    printf '%s' "$1" | sed -n "$_pat"
}

# --- WMO weather code -> words and glyph ----------------------------------
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

# Glyphs verified present in NotoSansCJKsc-Regular.otf: U+2600 U+2601 U+2602
wmo_icon() {
    case "$1" in
        0|1)                  printf '\342\230\200' ;;   # sun
        2|3|45|48)            printf '\342\230\201' ;;   # cloud
        51|53|55|56|57)       printf '\342\230\202' ;;   # umbrella
        61|63|65|66|67)       printf '\342\230\202' ;;
        71|73|75|77|85|86)    printf '\342\230\201' ;;
        80|81|82)             printf '\342\230\202' ;;
        95|96|99)             printf '\342\230\202' ;;
        *)                    printf '' ;;
    esac
}

# Same glyphs, chosen from a wttr.in condition string
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
weather_openmeteo() {  # $1=lat $2=lon $3=tz -> cache line on stdout
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
    _txt=$(http_get "https://wttr.in/$1,$2?format=%t|%f|%C|%h") || return 1
    [ -n "$_txt" ] || return 1
    case "$_txt" in *'|'*'|'*) ;; *) return 1 ;; esac

    _oldIFS="$IFS"; IFS='|'
    set -- $_txt
    IFS="$_oldIFS"
    [ $# -ge 4 ] || return 1

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
# Writes the cache file and echoes the cache line. Returns non-zero on failure.
weather_fetch() {
    _idx="$1"; _label="$2"; _lat="$3"; _lon="$4"; _tz="$5"
    _out=""

    if _out=$(weather_openmeteo "$_lat" "$_lon" "$_tz" "$_label" 2>>"$LOG_FILE"); then
        log "wx[$_idx] open-meteo ok: $_out"
    elif _out=$(weather_wttr "$_lat" "$_lon" "$_tz" "$_label" 2>>"$LOG_FILE"); then
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

    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "$_out" > "$STATE_DIR/wx$_idx.txt" 2>/dev/null
    LAST_WX_LINE="$_out"
    return 0
}

# weather_load <index> -> sets WX_* variables, returns 1 if no cache
weather_load() {
    _f="$STATE_DIR/wx$1.txt"
    [ -r "$_f" ] || return 1
    IFS='|' read -r WX_EPOCH WX_TEMP WX_FEELS WX_HUM WX_CODE WX_TMAX WX_TMIN \
                   WX_TEXT WX_ICON WX_LABEL WX_FETCH_HHMM < "$_f"
    [ -n "$WX_TEMP" ] || return 1
    return 0
}

# Time of the most recent successful fetch for location 0, for the footer.
weather_fetch_time() {
    [ -r "$STATE_DIR/wx0.txt" ] || return 1
    cut -d'|' -f11 "$STATE_DIR/wx0.txt" 2>/dev/null
}

# Sync the system clock from an HTTP Date header. Best effort, root only.
sync_time() {
    [ "${SYNC_TIME:-1}" = "1" ] || return 0
    _d=$(http_date_header "https://api.open-meteo.com/v1/forecast?latitude=0&longitude=0") || return 1
    [ -n "$_d" ] || return 1

    # "Thu, 02 Oct 2026 05:11:33 GMT"
    _oldIFS="$IFS"; IFS=' '
    set -- $_d
    IFS="$_oldIFS"
    _dow=$1; _day=$2; _mon=$3; _year=$4; _time=$5
    [ -n "$_year" ] && [ -n "$_time" ] || return 1

    case "$_mon" in
        Jan) _mm=01 ;; Feb) _mm=02 ;; Mar) _mm=03 ;; Apr) _mm=04 ;;
        May) _mm=05 ;; Jun) _mm=06 ;; Jul) _mm=07 ;; Aug) _mm=08 ;;
        Sep) _mm=09 ;; Oct) _mm=10 ;; Nov) _mm=11 ;; Dec) _mm=12 ;;
        *) return 1 ;;
    esac

    # sanity gates so a mangled header can never set a nonsense clock
    case "$_year" in 20[2-9][0-9]|21[0-9][0-9]) ;; *) return 1 ;; esac
    case "$_day" in [0-9]|[0-9][0-9]) ;; *) return 1 ;; esac
    case "$_time" in [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;; *) return 1 ;; esac

    if date -u -s "$_year-$_mm-$_day $_time" >/dev/null 2>&1; then
        log "time: synced to $_year-$_mm-$_day $_time UTC"
        return 0
    fi
    log "time: could not set clock (date -u -s unsupported?)"
    return 1
}
