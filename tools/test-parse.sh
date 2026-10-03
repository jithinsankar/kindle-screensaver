#!/bin/sh
# ============================================================================
#  Offline test for the weather parsers.
#
#  The Kindle has no jq, so lib/weather.sh pulls numbers out of Open-Meteo's
#  JSON with sed. That is the most fragile part of the project, so this test
#  exercises it against a live response plus a few synthetic edge cases.
#
#  Run on any machine with a POSIX shell + curl:
#      bash tools/test-parse.sh
# ============================================================================

HERE=$(dirname "$0")
LIB="$HERE/../device/lib/weather.sh"
UTIL="$HERE/../device/lib/util.sh"
[ -r "$LIB" ] || { echo "cannot find $LIB"; exit 1; }
[ -r "$UTIL" ] || { echo "cannot find $UTIL"; exit 1; }

# Load order matters: weather.sh uses round0() from util.sh, exactly as
# dashboard.sh loads them on the device.
LOG_FILE=/dev/null
. "$UTIL"
. "$LIB"

pass=0
fail=0
check() { # $1 = what, $2 = got, $3 = want
    if [ "$2" = "$3" ]; then
        printf 'ok   %-34s %s\n' "$1" "$2"
        pass=$(( pass + 1 ))
    else
        printf 'FAIL %-34s got=%s want=%s\n' "$1" "$2" "$3"
        fail=$(( fail + 1 ))
    fi
}

echo "--- synthetic JSON (deterministic) ---"
J='{"latitude":12.97,"longitude":77.59,"timezone":"Asia/Kolkata","current_units":{"time":"iso8601","temperature_2m":"°C","weather_code":"wmo code"},"current":{"time":"2026-10-02T10:30","interval":900,"temperature_2m":27.5,"apparent_temperature":30.1,"relative_humidity_2m":68,"weather_code":61},"daily_units":{"temperature_2m_max":"°C"},"daily":{"time":["2026-10-02"],"temperature_2m_max":[31.4],"temperature_2m_min":[21.6]}}'

CUR=$(json_section "$J" current)
DAY=$(json_section "$J" daily)

check "section: current has temp"   "$(json_num "$CUR" temperature_2m)"        "27.5"
check "section: current has code"   "$(json_num "$CUR" weather_code)"         "61"
check "section: current has feels"  "$(json_num "$CUR" apparent_temperature)" "30.1"
check "section: current has humid"  "$(json_num "$CUR" relative_humidity_2m)" "68"
check "section: daily max"          "$(json_num "$DAY" temperature_2m_max)"   "31.4"
check "section: daily min"          "$(json_num "$DAY" temperature_2m_min)"   "21.6"

# the unit block must NOT be mistaken for the values
check "units not parsed as temp"    "$(json_section "$J" current_units | json_num - temperature_2m)" ""

# negative temperatures
JN='{"current":{"temperature_2m":-7.4,"weather_code":71},"daily":{"temperature_2m_max":[-2.5],"temperature_2m_min":[-11.2]}}'
check "negative temp"               "$(json_num "$(json_section "$JN" current)" temperature_2m)"   "-7.4"
check "negative max in array"       "$(json_num "$(json_section "$JN" daily)" temperature_2m_max)" "-2.5"

echo
echo "--- rounding ---"
check "round 27.5"   "$(round0 27.5)"   "28"
check "round 27.4"   "$(round0 27.4)"   "27"
check "round -7.4"   "$(round0 -7.4)"   "-7"
check "round -7.6"   "$(round0 -7.6)"   "-8"
check "round 0"      "$(round0 0)"      "0"
check "round garbage" "$(round0 ab)"    "?"

echo
echo "--- WMO mapping ---"
check "code 0"   "$(wmo_text 0)"  "Clear"
check "code 2"   "$(wmo_text 2)"  "Partly cloudy"
check "code 61"  "$(wmo_text 61)" "Light rain"
check "code 95"  "$(wmo_text 95)" "Thunderstorm"
check "code 999" "$(wmo_text 999)" "Unknown"
echo "icons: 0=$(wmo_icon 0) 2=$(wmo_icon 2) 61=$(wmo_icon 61) 71=$(wmo_icon 71)"

echo
echo "--- fahrenheit conversion ---"
UNITS=celsius
check "celsius passthrough" "$(convert_units 27)" "27"
UNITS=fahrenheit
check "27C -> F"            "$(convert_units 27)" "81"
check "0C -> F"             "$(convert_units 0)"  "32"
check "-40C -> F"           "$(convert_units -40)" "-40"
UNITS=celsius

echo
echo "--- live Open-Meteo (Bengaluru) ---"
LIVE=$(curl -fsSL --max-time 20 \
    "https://api.open-meteo.com/v1/forecast?latitude=12.9716&longitude=77.5946&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=Asia/Kolkata&forecast_days=1" 2>/dev/null)
if [ -z "$LIVE" ]; then
    echo "skip (no network)"
else
    LC_=$(json_section "$LIVE" current)
    LD_=$(json_section "$LIVE" daily)
    T=$(json_num "$LC_" temperature_2m)
    W=$(json_num "$LC_" weather_code)
    MX=$(json_num "$LD_" temperature_2m_max)
    MN=$(json_num "$LD_" temperature_2m_min)
    echo "raw temp=$T code=$W max=$MX min=$MN"
    if [ -n "$T" ] && [ -n "$W" ] && [ -n "$MX" ] && [ -n "$MN" ]; then
        echo "ok   live parse produced all four fields"
        printf '     would render: %s  %s %s°  %s°/%s°\n' \
            "$(wmo_text "$W")" "$(wmo_icon "$W")" "$(round0 "$T")" \
            "$(round0 "$MX")" "$(round0 "$MN")"
        pass=$(( pass + 1 ))
    else
        echo "FAIL live parse: temp='$T' code='$W' max='$MX' min='$MN'"
        fail=$(( fail + 1 ))
    fi
fi

echo
echo "================================"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
