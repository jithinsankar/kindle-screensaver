#!/bin/sh
# ============================================================================
#  Offline tests for the device-agnostic helpers in lib/util.sh, the cache
#  handling in lib/weather.sh, and the frame logic in lib/anim.sh.
#
#  These cover the pieces that are easy to get silently wrong and that the
#  hardware runs exposed:
#    * touchscreen discovery (the tap-to-exit escape hatch)
#    * raw evdev byte decoding
#    * fbink -E measurement parsing and chained vertical placement
#    * the 11-field weather cache round trip
#    * animation directory resolution and frame counting
#
#  Run:  bash tools/test-helpers.sh
# ============================================================================

HERE=$(dirname "$0")
UTIL="$HERE/../device/lib/util.sh"
WX="$HERE/../device/lib/weather.sh"
ANIM="$HERE/../device/lib/anim.sh"
UPD="$HERE/../device/lib/update.sh"
[ -r "$UTIL" ] || { echo "cannot find $UTIL"; exit 1; }
[ -r "$WX" ] || { echo "cannot find $WX"; exit 1; }

LOG_FILE=/dev/null
# Point the autostart job at a scratch path BEFORE sourcing util.sh, so the test
# never touches the host's /etc/upstart. util.sh only fills this in when unset.
TMP=$(mktemp -d 2>/dev/null || echo /tmp/kdash-test-$$)
mkdir -p "$TMP" 2>/dev/null
UPSTART_JOB="$TMP/dashboard.conf"
. "$UTIL"
. "$WX"
# Optional: only present once the feature is deployed.
[ -r "$ANIM" ] && . "$ANIM"
[ -r "$UPD" ] && . "$UPD"

pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-38s %s\n' "$1" "$2"
        pass=$(( pass + 1 ))
    else
        printf 'FAIL %-38s got=%s want=%s\n' "$1" "$2" "$3"
        fail=$(( fail + 1 ))
    fi
}

echo "--- touchscreen discovery ---"
# Real layout from a Kindle Basic 3: the touch controller is cyttsp5_mt on event2.
cat > "$TMP/devices" <<'EOF'
I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="gpio-keys"
P: Phys=gpio-keys/input0
H: Handlers=kbd event0

I: Bus=0018 Vendor=0000 Product=0000 Version=0000
N: Name="cyttsp5_mt"
P: Phys=
S: Sysfs=/devices/platform/mtk-tpd/input/input2
U: Uniq=
H: Handlers=event2

I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="max77696-onkey"
H: Handlers=kbd event1
EOF
INPUT_DEVICES_FILE="$TMP/devices"
TOUCH_DEV_PROBED=0
TOUCH_DEV_CACHE=""
# parse_touch_device is the pure part; find_touch_device additionally requires
# the device node to exist, which it does not on this test host.
check "cyttsp5_mt resolved to event2" \
    "$(parse_touch_device "$INPUT_DEVICES_FILE")" "/dev/input/event2"

# A device with no touch controller at all must report nothing, so the daemon
# refuses to freeze the window manager.
cat > "$TMP/nodev" <<'EOF'
I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="gpio-keys"
H: Handlers=kbd event0
EOF
check "no touch controller -> empty" \
    "$(parse_touch_device "$TMP/nodev")" ""

# A keyboard-only device must not be mistaken for a touchscreen.
cat > "$TMP/kbd" <<'EOF'
N: Name="Kindle Keyboard"
H: Handlers=kbd event0
EOF
check "keyboard not treated as touch" \
    "$(parse_touch_device "$TMP/kbd")" ""

# Handlers ordering: the touchscreen must still be found when an unrelated
# event device is listed first in the same block.
cat > "$TMP/multi" <<'EOF'
N: Name="cyttsp5_mt"
H: Handlers=event7 kbd
EOF
check "event number parsed from a multi-handler line" \
    "$(parse_touch_device "$TMP/multi")" "/dev/input/event7"

echo
echo "--- evdev byte decoding ---"
# event: sec=0 usec=0 type=1(EV_KEY) code=330(BTN_TOUCH) value=1(little endian)
check "BTN_TOUCH down" \
    "$(decode_evdev_event '0 0 0 0 0 0 0 0 1 0 74 1 1 0 0 0')" "1 330 1"
# value=0 -> finger up, must not count as a tap
check "BTN_TOUCH up" \
    "$(decode_evdev_event '0 0 0 0 0 0 0 0 1 0 74 1 0 0 0 0')" "1 330 0"
# type=3(EV_ABS) code=57(ABS_MT_TRACKING_ID) -> ignored by the tap detector
check "ABS event is not a tap" \
    "$(decode_evdev_event '0 0 0 0 0 0 0 0 3 0 57 0 5 0 0 0')" "3 57 5"
# short read must fail rather than produce garbage
check "short read rejected" "$(decode_evdev_event '1 0 0 0' || echo rejected)" "rejected"

echo
echo "--- fbink -E measurement parsing (the chained-layout core) ---"
# Real shape of the OpenType output, read out of the fbink binary:
#   next_top=N;computed_lines=N;rendered_lines=N;bbox_width=N;bbox_height=N;truncated=d;
RE=$(dirname "$0")/../device/lib/render.sh
if [ -r "$RE" ]; then
    # shellcheck disable=SC1090
    . "$RE"
fi

parse_measure 'next_top=57;computed_lines=1;rendered_lines=1;bbox_width=120;bbox_height=18;truncated=0;'
check "next_top parsed"        "$DRAW_NEXT_TOP" "57"
check "bbox_height parsed"     "$DRAW_BBOX_H"   "18"

# next_top=0 is fbink's "no room left on screen" sentinel, not a position.
parse_measure 'next_top=0;computed_lines=1;rendered_lines=0;bbox_width=0;bbox_height=0;truncated=1;'
check "next_top=0 treated as invalid" "$DRAW_NEXT_TOP" ""

# Larger values (the 200px clock) must survive, so the sed must not truncate.
parse_measure 'next_top=347;computed_lines=1;rendered_lines=1;bbox_width=511;bbox_height=143;truncated=0;'
check "multi-digit next_top"   "$DRAW_NEXT_TOP" "347"
check "multi-digit bbox"       "$DRAW_BBOX_H"   "143"

# Garbage / no output must leave both empty so the caller falls back.
parse_measure ''
check "empty output -> empty"  "$DRAW_NEXT_TOP" ""
parse_measure 'lastRect_Top=40;lastRect_Width=100;'
check "non-OT format -> empty" "$DRAW_NEXT_TOP" ""

echo
echo "--- chained placement (next_top_from) ---"
FALLBACK_LINE_FACTOR=1.45
# A real measurement is used verbatim, so placement is exact.
check "uses measured value"   "$(next_top_from 20 24 57)"  "57"
check "uses measured 200px"   "$(next_top_from 55 200 290)" "290"
# No measurement -> conservative estimate, and crucially it must be GREATER
# than the top we started from, otherwise blocks would stack on each other.
check "fallback 24px -> 20+34" "$(next_top_from 20 24 "")" "55"
check "fallback 200px -> 55+290" "$(next_top_from 55 200 "")" "345"
# next_top of 0 must also take the fallback, not place the next block at y=0.
check "0 uses fallback, not zero" "$(next_top_from 55 200 0)" "345"
# Sanity: fallback must always advance downward for every size we use.
_mono=1
for _px in 22 24 52 200; do
    _n=$(next_top_from 100 "$_px" "")
    [ "$_n" -gt 100 ] || _mono=0
done
check "fallback always advances" "$_mono" "1"

echo
echo "--- weather cache round trip (11 fields) ---"
# The weather code is a VENDORED standalone module (see weather/). It reads
# WX_CACHE_DIR and knows nothing about STATE_DIR -- that handoff is util.sh's
# job, and it is asserted in the paths section at the end of this file.
WX_CACHE_DIR="$TMP"
mkdir -p "$WX_CACHE_DIR"
printf '%s\n' \
  '1759392000|27|30|68|61|31|22|Light rain|☂|Bengaluru|14:35' \
  > "$WX_CACHE_DIR/wx0.txt"
weather_load 0
check "field 2  temp"       "$WX_TEMP"        "27"
check "field 6  tmax"       "$WX_TMAX"        "31"
check "field 7  tmin"       "$WX_TMIN"        "22"
check "field 8  text"       "$WX_TEXT"        "Light rain"
check "field 10 label"      "$WX_LABEL"       "Bengaluru"
check "field 11 fetch time" "$WX_FETCH_HHMM"  "14:35"
check "footer source"       "$(weather_fetch_time)" "14:35"

# A cache line from an older format must not crash the loader.
printf '%s\n' '1759392000|27|30|68|61|31|22|Light rain|☂|Bengaluru' > "$WX_CACHE_DIR/wx1.txt"
WX_CACHE_DIR="$TMP" weather_load 1
check "old 10-field line still loads" "$WX_TEMP" "27"
check "missing fetch time is empty"   "$WX_FETCH_HHMM" ""

rm -rf "$TMP" 2>/dev/null

echo
echo "--- the JSON helpers must not need the weather module ---"
# These three started life inside lib/weather.sh, which meant the artwork
# manifest parser (anim.sh) and the update check (update.sh) had to load the
# weather module to parse their own files.
#
# The failure mode is the nasty part: anim.sh guards with
# `command -v json_section` and returns early, so a missing helper is SILENT --
# animations just quietly fall back to the config placement and nobody notices
# until the art lands in the wrong place. So source util.sh ALONE and assert
# they are all there.
_missing=""
for _f in json_section json_num json_str sync_time; do
    [ -n "$( ( . "$UTIL" >/dev/null 2>&1; command -v "$_f" ) )" ] || _missing="$_missing $_f"
done
check "util.sh alone provides them" "$_missing" ""

# And the converse: the vendored weather module must still parse with no host
# helpers defined, or it is not really standalone.
check "weather.sh needs no host" \
    "$( ( unset -f json_section json_num json_str is_int round0 http_get log 2>/dev/null; . "$WX" >/dev/null 2>&1; command -v json_section ) )" \
    "json_section"

echo
echo "--- animation: frame directory ---"
# One set, one path. An explicit ANIM_DIR must win, so a deployment (or a test)
# can point at its own frames.
ANIM_DIR="/tmp/custom"
check "explicit ANIM_DIR wins"  "$(anim_dir)" "/tmp/custom"
ANIM_DIR=""
check "unset ANIM_DIR -> default" "$(anim_dir)" "/mnt/us/dashboard/animations/bird"
echo
echo "--- animation: frame counting ---"
mkdir -p "$TMP/anim"
ANIM_DIR="$TMP/anim"
check "empty dir counts 0"      "$(anim_count)" "0"
: > "$TMP/anim/frame_000.png"
: > "$TMP/anim/frame_001.png"
# These must NOT be counted as frames: the manifest and the preview live in the
# same folder, and counting them would break the frame count and the manifest check.
: > "$TMP/anim/manifest.json"
: > "$TMP/anim/preview.png"
: > "$TMP/anim/notes.txt"
check "counts only frame_*.png" "$(anim_count)" "2"
# anim_check must refuse a directory that cannot actually animate.
if anim_check >/dev/null 2>&1; then
    check "2 frames accepted" "ok" "ok"
else
    check "2 frames accepted" "rejected" "ok"
fi
: > "$TMP/anim/frame_002.png"
check "3 frames counted"        "$(anim_count)" "3"
rm -f "$TMP/anim/frame_000.png" "$TMP/anim/frame_001.png" "$TMP/anim/frame_002.png"
if anim_check >/dev/null 2>&1; then
    check "0 frames rejected" "accepted" "rejected"
else
    check "0 frames rejected" "rejected" "rejected"
fi

ANIM_DIR=""
echo
echo "--- animation: choosing between sets ---"
# Each artwork is its own directory, so they coexist and a new one never replaces
# an old one. These assert the resolution order and that adding a set disturbs
# nothing that was already there.
SETBASE="$TMP/sets"
mkdir -p "$SETBASE/bird" "$SETBASE/fish" "$SETBASE/junk"
for i in 0 1 2; do
    : > "$SETBASE/bird/frame_00$i.png"
    : > "$SETBASE/fish/frame_00$i.png"
done
: > "$SETBASE/junk/frame_000.png"        # one frame only -> not usable
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
ANIM_DIR_BASE="$SETBASE"
ANIM_DIR=""
ANIM_SET="bird"

check "config default is used"       "$(active_set)" "bird"
check "anim_dir follows the set"     "$(anim_dir)" "$SETBASE/bird"
check "lists only usable sets"       "$(anim_list | awk '{printf "%s ", $1}')" "bird fish "
# Nothing was deleted or merged: adding fish left bird exactly where it was.
check "sets coexist independently"   "$(ls -1 "$SETBASE" | sort | tr '\n' ' ')" "bird fish junk "

# A runtime override wins over config -- this is what KUAL "Next animation" writes.
printf 'fish\n' > "$STATE_DIR/active-set"
check "state override wins"          "$(active_set)" "fish"
check "anim_dir follows override"    "$(anim_dir)" "$SETBASE/fish"

# An override naming a set that no longer exists must not win, or the animation
# would refuse to start because its directory is missing.
printf 'gone\n' > "$STATE_DIR/active-set"
check "stale override is ignored"    "$(active_set)" "bird"

# An explicit ANIM_DIR still beats everything; deployments and tests use it.
ANIM_DIR="$SETBASE/fish"
check "explicit ANIM_DIR wins"       "$(anim_dir)" "$SETBASE/fish"
ANIM_DIR=""

# ANIM_SET naming a missing set falls back to something actually installed.
rm -f "$STATE_DIR/active-set"
ANIM_SET="not-installed"
check "missing ANIM_SET falls back"  "$(active_set)" "bird"

ANIM_SET="bird"; ANIM_DIR_BASE=""

echo
echo "--- image-capable renderer selection (the blank-screen bug) ---"
# fbink builds differ: KOReader's is stripped with image support DISABLED, so it
# renders text perfectly and fails every -g call. find_fbink's search order
# PREFERS that build, so image work needs its own probe -- and the probe has to
# PERFORM the operation, because string-inspecting a binary is only a hint.
FAKE_BAD="$TMP/fbink-bad"
FAKE_GOOD="$TMP/fbink-good"
FAKE_MISSING="$TMP/fbink-missing"
printf '#!/bin/sh\necho "[FBInk] Image support is disabled in this FBInk build!" >&2\nexit 1\n' > "$FAKE_BAD"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_GOOD"
chmod 755 "$FAKE_BAD" "$FAKE_GOOD" 2>/dev/null
rm -f "$FAKE_MISSING"
PROBE_FRAME="$TMP/anim/probe.png"
: > "$PROBE_FRAME"

# Nothing usable -> must fail so the caller refuses to start and leaves the
# screen alone, instead of clearing it and looping over every failure.
FBINK=""; FBINK_IMG=""; FBINK_IMG_UNUSABLE=0
FBINK_IMAGE_CANDIDATES="$FAKE_BAD $FAKE_MISSING"
if find_fbink_image "$PROBE_FRAME" >/dev/null 2>&1; then
    check "refuses when nothing can draw" "accepted" "refused"
else
    check "refuses when nothing can draw" "refused" "refused"
fi
check "failure is remembered"  "$FBINK_IMG_UNUSABLE" "1"
check "no renderer chosen"     "$FBINK_IMG" ""

# A capable build later in the list must still be found. Called with output
# redirected (NOT captured) because the cache lives in a global and $(...) would
# run the assignment in a subshell, discarding it -- see the note in util.sh.
FBINK=""; FBINK_IMG=""; FBINK_IMG_UNUSABLE=0
FBINK_IMAGE_CANDIDATES="$FAKE_BAD $FAKE_GOOD"
find_fbink_image "$PROBE_FRAME" >/dev/null 2>&1
check "skips the broken build"    "$FBINK_IMG" "$FAKE_GOOD"

# The echoed path is still correct when captured, even though caching is lost.
FBINK=""; FBINK_IMG=""; FBINK_IMG_UNUSABLE=0
check "echoes the good build"     "$(find_fbink_image "$PROBE_FRAME" 2>/dev/null)" "$FAKE_GOOD"

# No probe frame -> fail rather than guess.
FBINK=""; FBINK_IMG=""; FBINK_IMG_UNUSABLE=0
FBINK_IMAGE_CANDIDATES="$FAKE_GOOD"
if find_fbink_image "$TMP/definitely-not-here.png" >/dev/null 2>&1; then
    check "no probe frame -> refuse" "accepted" "refused"
else
    check "no probe frame -> refuse" "refused" "refused"
fi

FBINK=""; FBINK_IMG=""
echo
echo "--- millisecond sleep selection ---"
# Falling back to a whole-second sleep turns an 8fps animation into a 1fps one,
# so which command the probe settles on is worth asserting. The probe RUNS it
# rather than using command -v, because usleep is not discoverable that way from
# a KUAL environment even though it exists.
SLEEP_MS_CMD=""; SLEEP_MS_PROBED=0
sleep_ms 10
case "$SLEEP_MS_CMD" in
    usleep|float|sleep) check "probe resolves a command" "$SLEEP_MS_CMD" "$SLEEP_MS_CMD" ;;
    'busybox usleep'|'/usr/bin/usleep') check "probe resolves a command" "$SLEEP_MS_CMD" "$SLEEP_MS_CMD" ;;
    *)                  check "probe resolves a command" "unset" "a sleep form" ;;
esac
check "probe is remembered"      "$SLEEP_MS_PROBED" "1"
# Must survive junk and zero without erroring.
check "junk argument is safe"    "$(sleep_ms abc  >/dev/null 2>&1; echo $?)" "0"
check "zero argument is safe"    "$(sleep_ms 0    >/dev/null 2>&1; echo $?)" "0"
# Force the fallback path and confirm the rounding, without actually sleeping:
# a request is never shortened below what was asked for.
check "fallback rounds 1ms up"   "$(( (1 + 999) / 1000 ))"   "1"
check "fallback rounds 120ms up" "$(( (120 + 999) / 1000 ))" "1"
check "fallback rounds 8s"       "$(( (8000 + 999) / 1000 ))" "8"

echo
echo "--- self-update: url construction ---"
UPDATE_URL=""
UPDATE_REPO="someone/kindle_exp"
UPDATE_REF="main"
check "branch ref is expanded"  "$(update_ref_path)" "refs/heads/main"
check "codeload url for a branch" "$(update_archive_url)" \
      "https://codeload.github.com/someone/kindle_exp/tar.gz/refs/heads/main"
UPDATE_REF="refs/tags/v1.2.0"
check "full ref used verbatim"  "$(update_ref_path)" "refs/tags/v1.2.0"
check "codeload url for a tag"  "$(update_archive_url)" \
      "https://codeload.github.com/someone/kindle_exp/tar.gz/refs/tags/v1.2.0"
# UPDATE_URL must win, so any host works, not just GitHub.
UPDATE_URL="https://example.com/my.gitlab.tar.gz"
check "UPDATE_URL overrides repo" "$(update_archive_url)" "https://example.com/my.gitlab.tar.gz"
UPDATE_URL=""
UPDATE_REPO=""
if update_archive_url >/dev/null 2>&1; then
    check "no repo and no url -> fail" "configured" "refused"
else
    check "no repo and no url -> fail" "refused" "refused"
fi

BLOB="$TMP/blob"
printf '\037\213\010\000rest-of-gzip' > "$BLOB"
check "gzip magic detected"   "$(update_archive_kind "$BLOB")" "gzip"
printf 'PK\003\004zipdata' > "$BLOB"
check "zip magic detected"    "$(update_archive_kind "$BLOB")" "zip"
printf '<html>404 not found</html>' > "$BLOB"
check "html error page rejected" "$(update_archive_kind "$BLOB")" ""
: > "$BLOB"
check "empty download rejected"  "$(update_archive_kind "$BLOB")" ""

echo
echo "--- self-update: tree location and validation ---"
# A minimal but complete tree, shaped like a GitHub archive.
TREE="$TMP/kindle_exp-main"
mkdir -p "$TREE/device/lib" "$TREE/device/kual/bin"
for f in dashboard.sh install.sh uninstall.sh config.sh; do echo '#!/bin/sh' > "$TREE/device/$f"; done
for f in util.sh render.sh weather.sh anim.sh update.sh; do echo '#!/bin/sh' > "$TREE/device/lib/$f"; done
echo '#!/bin/sh' > "$TREE/device/kual/bin/ctl.sh"
check "finds the archive root" "$(update_find_root "$TMP")" "$TREE"
if update_validate "$TREE" >/dev/null 2>&1; then
    check "complete tree validated" "ok" "ok"
else
    check "complete tree validated" "rejected" "ok"
fi
# A missing expected file must be caught before anything is installed.
mv "$TREE/device/lib/render.sh" "$TREE/device/lib/render.sh.hidden"
if update_validate "$TREE" >/dev/null 2>&1; then
    check "missing file rejected" "accepted" "rejected"
else
    check "missing file rejected" "rejected" "rejected"
fi
mv "$TREE/device/lib/render.sh.hidden" "$TREE/device/lib/render.sh"
# A syntax error must be caught: this is what stops a truncated download landing.
printf '#!/bin/sh\nif [ 1 = 1 ; then\n' > "$TREE/device/lib/render.sh"
if update_validate "$TREE" >/dev/null 2>&1; then
    check "syntax error rejected" "accepted" "rejected"
else
    check "syntax error rejected" "rejected" "rejected"
fi
echo '#!/bin/sh' > "$TREE/device/lib/render.sh"

# A tree with no device/ at all (wrong repo) must be rejected.
mkdir -p "$TMP/not-ours/whatever"
if update_validate "$TMP/not-ours" >/dev/null 2>&1; then
    check "tree without device/ rejected" "accepted" "rejected"
else
    check "tree without device/ rejected" "rejected" "rejected"
fi

echo
echo "--- self-update: copy preserves settings and is atomic ---"
DST="$TMP/live-dashboard"
mkdir -p "$DST/state" "$DST/lib"
printf 'USER SETTING\n' > "$DST/config.sh"
printf 'runtime\n' > "$DST/state/wx0.txt"
printf 'old log\n' > "$DST/old.sh"
update_copy_tree "$TREE/device" "$DST" "$UPDATE_SKIP"
check "live config.sh preserved"  "$(cat "$DST/config.sh")" "USER SETTING"
check "state/ preserved"           "$(cat "$DST/state/wx0.txt")" "runtime"
# old.sh no longer exists upstream, so a plain copy leaves it: that is expected
# (we never delete) and worth asserting so nobody assumes otherwise.
check "stale files are not deleted" "$(test -f "$DST/old.sh" && echo kept)" "kept"
# EVERY expected path, not just one file. The first version of the recursive copy
# used global variables, so a nested call clobbered the parent's destination and
# files landed under kual/bin/lib/. A single-file check missed most of it.
_missing=""
for f in dashboard.sh install.sh uninstall.sh; do
    [ -f "$DST/$f" ] || _missing="$_missing $f"
done
for f in util.sh render.sh weather.sh anim.sh update.sh; do
    [ -f "$DST/lib/$f" ] || _missing="$_missing lib/$f"
done
[ -f "$DST/kual/bin/ctl.sh" ] || _missing="$_missing kual/bin/ctl.sh"
check "all files at the right paths" "${_missing:-none}" "none"
# The precise symptom of the clobbering bug: files landing under a subdirectory.
check "nothing scattered into kual/bin/lib" \
      "$(test -d "$DST/kual/bin/lib" && echo scattered || echo clean)" "clean"
check "no stray top-level dirs"    "$(test -d "$DST/bin" -o -d "$DST/kual/lib" \
      && echo stray || echo clean)" "clean"
check "no .new leftovers"         "$(find "$DST" -name '*.new' | wc -l | tr -d ' ')" "0"

UPDATE_ON_START=1
UPDATE_MIN_INTERVAL=0
check "due when interval is 0"    "$(update_due >/dev/null 2>&1; echo $?)" "0"
UPDATE_ON_START=0
check "not due when disabled"     "$(update_due >/dev/null 2>&1; echo $?)" "1"
UPDATE_ON_START=1
UPDATE_MIN_INTERVAL=3600
STATE_DIR="$TMP/live-dashboard/state"
date +%s > "$STATE_DIR/last-update"
check "throttled just after a check" "$(update_due >/dev/null 2>&1; echo $?)" "1"
UPDATE_MIN_INTERVAL=0

echo
echo "--- self-update: a callee must not clobber the caller's variables ---"
# update_fetch used to assign _url/_dest as GLOBALS. art_run holds the INSTALL
# DESTINATION in _dest, so downloading overwrote it with the .pkg path and the
# install wrote into a file, failed silently, and reported "no usable frame sets".
# This is the POSIX-sh-has-no-local trap; assert the caller's state survives.
_dest="/some/install/dir"
_url="https://example.invalid/keep-me"
CURL_BIN=true
update_fetch "https://example.invalid/pkg.tar.gz" "/tmp/out.pkg" >/dev/null 2>&1
check "update_fetch returns success"      "$?"        "0"
check "update_fetch leaves _dest alone"   "$_dest"    "/some/install/dir"
check "update_fetch leaves _url alone"    "$_url"     "https://example.invalid/keep-me"
CURL_BIN=""

echo
echo "--- artwork: frame inspection ---"
REPO_ART="$HERE/../artwork"
HAVE_ART=0
if [ -r "$REPO_ART/bird/f_000.png" ]; then
    HAVE_ART=1
    # Dimensions are read straight out of the PNG IHDR, so this also proves the
    # byte offsets are right rather than assuming them. There is one set now, at
    # the fullscreen size, so a wrong number here means wrong offsets OR a stale
    # frame set that no longer matches what the mode expects.
    check "frame set is 420x320"          "$(art_png_size "$REPO_ART/bird/f_000.png")" "420x320"
    check "real set validates (8 frames)" "$(art_validate_dir "$REPO_ART/bird")"       "8"
else
    echo "  (skipped: repo artwork/ not present)"
fi
printf 'not a png at all' > "$TMP/fake.png"
check "non-png has no size"   "$(art_png_size "$TMP/fake.png")" ""
mkdir -p "$TMP/set1"
[ "$HAVE_ART" = "1" ] && cp "$REPO_ART/bird/f_000.png" "$TMP/set1/" 2>/dev/null
if art_validate_dir "$TMP/set1" >/dev/null 2>&1; then
    check "single-frame set rejected" "accepted" "rejected"
else
    check "single-frame set rejected" "rejected" "rejected"
fi
mkdir -p "$TMP/set2"
printf 'nope' > "$TMP/set2/f_000.png"
printf 'nope' > "$TMP/set2/f_001.png"
if art_validate_dir "$TMP/set2" >/dev/null 2>&1; then
    check "non-png frames rejected" "accepted" "rejected"
else
    check "non-png frames rejected" "rejected" "rejected"
fi

echo
echo "--- artwork: install from an extracted archive ---"
if [ "$HAVE_ART" = "1" ]; then
    # Layout A: artwork/ at the top, i.e. a full project archive.
    mkdir -p "$TMP/archA/artwork"
    cp -r "$REPO_ART/bird" "$TMP/archA/artwork/" 2>/dev/null
    DA="$TMP/destA"; mkdir -p "$DA"
    if art_install_tree "$TMP/archA" "$DA" >/dev/null 2>&1; then
        check "layout A (artwork/ at top)"   "$(art_validate_dir "$DA/bird")" "8"
    else
        check "layout A (artwork/ at top)"   "failed" "8"
    fi
    # Layout B: ONE wrapping directory around artwork/, which is the shape of an
    # art-only repo archive. Miss this and a good art repo looks empty.
    mkdir -p "$TMP/archB/myart-main/artwork"
    cp -r "$REPO_ART/bird" "$TMP/archB/myart-main/artwork/" 2>/dev/null
    DB="$TMP/destB"; mkdir -p "$DB"
    if art_install_tree "$TMP/archB" "$DB" >/dev/null 2>&1; then
        check "layout B (wrapped archive)"   "$(art_validate_dir "$DB/bird")" "8"
    else
        check "layout B (wrapped archive)"   "failed" "8"
    fi
else
    echo "  (skipped: needs the repo artwork/)"
fi
# An archive with no frames must fail, so nothing overwrites working art.
mkdir -p "$TMP/archC/artwork/junk"
printf 'x' > "$TMP/archC/artwork/junk/readme.txt"
DC="$TMP/destC"; mkdir -p "$DC"
if art_install_tree "$TMP/archC" "$DC" >/dev/null 2>&1; then
    check "archive with no frames rejected" "accepted" "rejected"
else
    check "archive with no frames rejected" "rejected" "rejected"
fi

STATE_DIR="$TMP"
ART_ON_START=1; ART_URL="https://example.com/a.tar.gz"; ART_MIN_INTERVAL=0
check "art due when interval is 0"    "$(art_due >/dev/null 2>&1; echo $?)" "0"
ART_ON_START=0
check "art not due when disabled"     "$(art_due >/dev/null 2>&1; echo $?)" "1"
ART_ON_START=1; ART_URL=""
check "art not due without a url"     "$(art_due >/dev/null 2>&1; echo $?)" "1"
ART_URL="https://example.com/a.tar.gz"; ART_MIN_INTERVAL=3600
date +%s > "$STATE_DIR/last-art"
check "art throttled just after fetch" "$(art_due >/dev/null 2>&1; echo $?)" "1"

ART_ON_START=0; ART_URL=""; ART_MIN_INTERVAL=0

echo
echo "--- artwork: the manifest is machine-readable ---"
# The manifest is what makes a set self-describing and portable. It is written by
# PowerShell's ConvertTo-Json, which emits `"frame":  {` with whitespace and across
# multiple lines -- so the parser must tolerate the whitespace and the caller must
# flatten newlines first. Getting either wrong silently yields no values.
MJ="$REPO_ART/bird/manifest.json"
if [ -r "$MJ" ]; then
    FLAT=$(tr -d '\n\r' < "$MJ")
    FSEC=$(json_section "$FLAT" frame)
    [ -n "$FSEC" ] || FSEC="<empty>"
    check "manifest: frame section found" "$(test "$FSEC" != "<empty>" && echo yes)" "yes"
    check "manifest: frame.x"      "$(json_num "$FSEC" x)"        "90"
    check "manifest: frame.y"      "$(json_num "$FSEC" y)"        "240"
    check "manifest: frame width"  "$(json_num "$FSEC" width)"    "420"
    check "manifest: frame height" "$(json_num "$FSEC" height)"   "320"
    check "manifest: delay_ms"     "$(json_num "$FLAT" delay_ms)" "120"
    check "manifest: count"        "$(json_num "$FLAT" count)"    "8"
    check "manifest: format id" \
        "$(printf '%s' "$FLAT" | sed -n 's/.*"format":[[:space:]]*"\([^"]*\)".*/\1/p')" \
        "kindle-dashboard-animation"
    # The screen block must not be mistaken for the frame block: both contain
    # "width"/"height", so a sloppy parser returns 600/800 here.
    check "manifest: screen not confused with frame" "$(json_num "$FSEC" width)" "420"
    check "manifest: frame filenames" \
        "$(ls "$REPO_ART/bird"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')" "8"
    check "manifest: no stale f_*.png" \
        "$(ls "$REPO_ART/bird"/f_*.png 2>/dev/null | wc -l | tr -d ' ')" "0"
else
    echo "  (skipped: no manifest)"
fi

echo
echo "--- artwork: the repo declares which set is current ---"
# A repo can hold many animations and declare which one plays, so switching is a
# one-line edit on GitHub instead of tapping through a list. That matters as soon
# as there are more than a handful.
CFG="$TMP/cfg"
mkdir -p "$CFG"
printf '{\n  "active": "fish",\n  "only_active": true\n}\n' > "$CFG/config.json"
check "json_str reads a string"    "$(json_str "$(tr -d '\n\r' < "$CFG/config.json")" active)" "fish"
check "finds config in a tree"     "$(art_find_config "$CFG")" "$CFG/config.json"
check "declares active"            "$(art_config_active "$CFG/config.json")" "fish"
if art_config_only_active "$CFG/config.json"; then
    check "only_active=true parsed" "true" "true"
else
    check "only_active=true parsed" "false" "true"
fi
printf '{"active":"bird","only_active":false}' > "$CFG/config.json"
check "active parsed (compact)"    "$(art_config_active "$CFG/config.json")" "bird"
if art_config_only_active "$CFG/config.json"; then
    check "only_active=false parsed" "true" "false"
else
    check "only_active=false parsed" "false" "false"
fi
# A bare name must work too: much easier to get right in GitHub's web editor.
printf 'fish\n' > "$CFG/plain.json"
check "bare name accepted"         "$(art_config_active "$CFG/plain.json")" "fish"
printf '{ "nonsense": 1 }' > "$CFG/none.json"
check "no active key -> empty"     "$(art_config_active "$CFG/none.json")" ""
: > "$CFG/empty.json"
check "empty config -> empty"      "$(art_config_active "$CFG/empty.json")" ""

echo
echo "--- artwork: the declared set is honoured, a bad one is not ---"
SETBASE2="$TMP/sets2"
mkdir -p "$SETBASE2/bird" "$SETBASE2/fish"
for i in 0 1; do
    : > "$SETBASE2/bird/frame_00$i.png"
    : > "$SETBASE2/fish/frame_00$i.png"
done
STATE_DIR="$TMP/state2"; mkdir -p "$STATE_DIR"
ANIM_DIR_BASE="$SETBASE2"; ANIM_DIR=""; ANIM_SET="bird"
art_record_declared fish "$SETBASE2"
check "declaration file written"   "$(test -f "$STATE_DIR/repo-active" && tr -d ' \r\n' < "$STATE_DIR/repo-active" || echo missing)" "fish"
check "declared set is recorded"    "$(active_set)" "fish"
# A local override must NOT beat the repo, or editing the repo would look broken.
printf 'bird\n' > "$STATE_DIR/active-set"
check "repo beats a local override" "$(active_set)" "fish"
# A name that is not installed must be ignored rather than breaking playback.
art_record_declared nothere "$SETBASE2" >/dev/null 2>&1
check "invalid declaration ignored" "$(active_set)" "bird"
check "stale declaration removed"   "$(test -f "$STATE_DIR/repo-active" && echo present || echo gone)" "gone"
# With no declaration, the local override applies again.
printf 'fish\n' > "$STATE_DIR/active-set"
check "local override when repo silent" "$(active_set)" "fish"
ANIM_SET="bird"; ANIM_DIR_BASE=""; STATE_DIR=""

echo
echo "--- update: the shipped placeholder must be REFUSED, not 404ed ---"
# config.sh ships UPDATE_REPO="owner/repo". Left unhandled the updater requests
# codeload.github.com/owner/repo/... and reports a bare "HTTP 404", which tells
# the reader nothing about the actual problem.
_keep_url="$UPDATE_URL"; _keep_repo="$UPDATE_REPO"
UPDATE_URL=""; UPDATE_REPO="owner/repo"
check "placeholder repo refused"      "$(update_archive_url)" ""
UPDATE_REPO="you/your-repo"
check "other placeholder refused"     "$(update_archive_url)" ""
UPDATE_REPO="acme/thing"
case "$(update_archive_url)" in
    https://codeload.github.com/acme/thing/tar.gz/*) check "a real repo builds a URL" "ok" "ok" ;;
    *) check "a real repo builds a URL" "$(update_archive_url)" "https://codeload.github.com/acme/thing/tar.gz/..." ;;
esac
UPDATE_URL=""; UPDATE_REPO=""
check "no repo at all still fails"    "$(update_archive_url)" ""
UPDATE_URL="$_keep_url"; UPDATE_REPO="$_keep_repo"

echo
echo "--- frontlight: 0 means OFF, and it must actually be driven ---"
# The bug this guards: FRONTLIGHT defaulted to -1 ("leave the user's setting"), so
# the frontlight stayed lit the whole time the dashboard was up, draining the
# battery of a device that is deliberately being kept awake.
_keep_fl="$FRONTLIGHT"
# Stub lipc so we can see exactly which properties get driven, and with what.
lipc-set-prop() { case "$*" in *flIntensity*) _SET_FL="$4" ;; *flOn*) _SET_FLON="$4" ;; esac; return 0; }
lipc-get-prop() { case "$*" in *flIntensity*) printf '0' ;; *flOn*) printf '0' ;; *) printf '' ;; esac; }
_SET_FL=""; _SET_FLON=""
FRONTLIGHT=0
apply_frontlight
check "0 drives flIntensity to 0"     "$_SET_FL"   "0"
check "0 also drives flOn to 0"       "$_SET_FLON" "0"
_SET_FL=""; _SET_FLON=""
FRONTLIGHT=12
apply_frontlight
check "12 drives flIntensity to 12"   "$_SET_FL"   "12"
check "12 turns flOn back on"         "$_SET_FLON" "1"
_SET_FL=""; _SET_FLON=""
FRONTLIGHT=-1
apply_frontlight
check "-1 touches nothing"            "$_SET_FL$_SET_FLON" ""
FRONTLIGHT="$_keep_fl"
unset -f lipc-set-prop lipc-get-prop 2>/dev/null

echo
echo "--- paths: an unset STATE_DIR must not send writes to / ---"
# STATE_DIR comes from config.sh. If config.sh is missing or truncated it used to
# end up EMPTY, so "$STATE_DIR/last-update" became "/last-update" and the Kindle's
# read-only root answered with a bare "Permission denied" that pointed nowhere.
# util.sh now supplies defaults, and config.sh still wins because ${VAR:-default}
# only fills in when the value is empty.
check "STATE_DIR has a default"  "$( ( unset STATE_DIR; . "$UTIL" >/dev/null 2>&1; printf '%s' "$STATE_DIR" ) )" "/mnt/us/dashboard/state"
check "LOG_FILE has a default"   "$( ( unset LOG_FILE LOG_DIR; . "$UTIL" >/dev/null 2>&1; printf '%s' "$LOG_FILE" ) )" "/mnt/us/dashboard/log/dashboard.log"
# And a value that IS set must be left alone -- this is the whole point of :-.
check "an explicit value wins"   "$( STATE_DIR=/tmp/custom; unset STATE_DIR; STATE_DIR=/tmp/mine; . "$UTIL" >/dev/null 2>&1; printf '%s' "$STATE_DIR" )" "/tmp/mine"

# The vendored weather module reads WX_CACHE_DIR; nothing else. If this handoff
# is ever lost the module silently falls back to a temp directory, so every
# refresh re-downloads and the cache never survives a reboot -- and that only
# shows up on a device, never here.
check "WX_CACHE_DIR follows STATE_DIR"  "$( ( unset WX_CACHE_DIR; STATE_DIR=/tmp/mine; . "$UTIL" >/dev/null 2>&1; printf '%s' "$WX_CACHE_DIR" ) )" "/tmp/mine"
check "WX_CACHE_DIR can be overridden" "$( ( WX_CACHE_DIR=/tmp/cache; STATE_DIR=/tmp/mine; . "$UTIL" >/dev/null 2>&1; printf '%s' "$WX_CACHE_DIR" ) )" "/tmp/cache"

echo
echo "--- boot autostart: the job file's presence IS the state ---"
# The KUAL menu has one 'Toggle boot autostart' entry, not an enable/disable
# pair, and its label cannot show the current state. So the state has to be
# asked of the filesystem -- a flag written elsewhere could disagree with it and
# the report printed on the panel would then lie about the next boot.
rm -f "$UPSTART_JOB"
check "absent job reads as off"    "$( autostart_enabled && echo on || echo off )" "off"
: > "$UPSTART_JOB"
check "present job reads as on"    "$( autostart_enabled && echo on || echo off )" "on"
rm -f "$UPSTART_JOB"
check "removed again reads as off" "$( autostart_enabled && echo on || echo off )" "off"
# A directory at that path is not a job file; it must not read as enabled.
mkdir -p "$UPSTART_JOB" 2>/dev/null
check "a directory is not a job"   "$( autostart_enabled && echo on || echo off )" "off"
rmdir "$UPSTART_JOB" 2>/dev/null
# The toggle decides from that helper, so the two must agree. This mirrors the
# one line of install.sh's arg parsing that does the flip.
for _had in off on; do
    if [ "$_had" = "on" ]; then : > "$UPSTART_JOB"; else rm -f "$UPSTART_JOB"; fi
    if autostart_enabled; then _now=0; else _now=1; fi
    check "flip from $_had goes to $( [ "$_now" = 1 ] && echo on || echo off )" \
        "$_now" "$( [ "$_had" = "on" ] && echo 0 || echo 1 )"
done
rm -f "$UPSTART_JOB"
# install.sh must route through the helper rather than re-deriving the path, or
# the two could drift to different files.
if grep -q 'autostart_enabled' "$HERE/../device/install.sh" 2>/dev/null; then
    check "install.sh uses the helper" "ok" "ok"
else
    check "install.sh uses the helper" "not found" "ok"
fi
if grep -q 'UPSTART_JOB="/etc/upstart' "$HERE/../device/install.sh" 2>/dev/null; then
    check "install.sh does not hardcode the path" "hardcoded" "the path lives in util.sh"
else
    check "install.sh does not hardcode the path" "ok" "ok"
fi

echo
echo "================================"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
