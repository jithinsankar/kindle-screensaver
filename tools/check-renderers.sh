#!/bin/sh
# ============================================================================
#  Find an fbink build that can actually draw images.
#
#  WHY THIS EXISTS: fbink is compiled with optional features, and the stripped
#  copy KOReader ships has image support DISABLED. So a build that renders text
#  perfectly will fail every `-g, --image` call with:
#
#      [FBInk] Image support is disabled in this FBInk build!
#
#  Which binary you get depends on search order, so "fbink works" is not a
#  single fact -- it is per binary and per feature. This script checks each
#  candidate on the device and reports what each one can do.
#
#  Run on the Kindle (or from Windows via Git Bash):
#      sh tools/check-renderers.sh
#      sh tools/check-renderers.sh /mnt/us/dashboard/animations/bird/f_000.png
# ============================================================================

# Where the Kindle's user partition is mounted, as seen by this shell. Override
# with KINDLE_US if you are running it under Git Bash, where it is normally /f.
KINDLE_US="${KINDLE_US:-/mnt/us}"
[ -d "$KINDLE_US" ] || KINDLE_US=/f
[ -d "$KINDLE_US" ] || { echo "cannot find the Kindle user partition; set KINDLE_US"; exit 1; }

PROBE_IMAGE="${1:-$KINDLE_US/dashboard/animations/bird/f_000.png}"

echo "user partition : $KINDLE_US"
echo "probe image    : $PROBE_IMAGE"
if [ -f "$PROBE_IMAGE" ]; then
    echo "probe image    : present ($(wc -c < "$PROBE_IMAGE" | tr -d ' ') bytes)"
else
    echo "probe image    : MISSING (will still report capabilities, but cannot live-test)"
fi
echo

# --- candidate binaries ----------------------------------------------------
CANDIDATES="
$KINDLE_US/libkh/bin/fbink
$KINDLE_US/koreader/fbink
$KINDLE_US/extensions/MRInstaller/bin/KHF/fbink
$KINDLE_US/dashboard/bin/fbink
"
# plus anything else on the device
EXTRA=$(find "$KINDLE_US" -maxdepth 5 -type f -name 'fbink' 2>/dev/null | head -n 20)

echo "=== fbink binaries ==="
printf '%-52s %9s  %-9s %s\n' "path" "bytes" "image?" "evidence"
echo "-----------------------------------------------------------------------------------------------"

_seen=""
for f in $CANDIDATES $EXTRA; do
    [ -n "$f" ] || continue
    case "$_seen" in *"|$f|"*) continue ;; esac
    _seen="$_seen|$f|"
    if [ ! -f "$f" ]; then
        printf '%-52s %9s  %-9s %s\n' "$f" "-" "-" "missing"
        continue
    fi
    _sz=$(wc -c < "$f" | tr -d ' ')
    if grep -qa 'Image support is disabled' "$f" 2>/dev/null; then
        _img="NO"
        _why="binary contains the 'disabled' error string"
    else
        _img="maybe"
        _why="no 'disabled' string (test it below)"
    fi
    printf '%-52s %9s  %-9s %s\n' "$f" "$_sz" "$_img" "$_why"
done

# --- live test -------------------------------------------------------------
# Strings are a hint, not proof: actually try the call and read the exit code.
echo
echo "=== live image test (draws into the framebuffer only, -b = no refresh) ==="
if [ ! -f "$PROBE_IMAGE" ]; then
    echo "skipped: no probe image"
else
    for f in $CANDIDATES $EXTRA; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        _out=$("$f" -q -b -g "file=$PROBE_IMAGE,x=0,y=0" 2>&1)
        _rc=$?
        case "$_out" in
            *'Exec format error'*)
                # These are Kindle ARM binaries. Running this script under Git
                # Bash on Windows cannot execute them, so do not report a
                # capability verdict that was never actually measured.
                echo "  SKIP    $f"
                echo "            cannot execute a Kindle binary on $(uname -s 2>/dev/null || echo this host);"
                echo "            run this script ON the Kindle for a live answer."
                ;;
            *)
                if [ "$_rc" -eq 0 ] && [ -z "$_out" ]; then
                    echo "  OK      $f"
                else
                    echo "  FAILED  $f  (rc=$_rc)"
                    [ -n "$_out" ] && printf '%s\n' "$_out" | head -n 3 | sed 's/^/            /'
                fi
                ;;
        esac
    done
fi

# --- other image paths ----------------------------------------------------
echo
echo "=== other ways to put a bitmap on the panel ==="
for t in eips fbdepth fbgrab einkpdf; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "  $t: $(command -v $t)"
    else
        echo "  $t: not on PATH"
    fi
done
# eips often lives outside PATH
for p in /usr/bin/eips /usr/sbin/eips "$KINDLE_US/../usr/bin/eips"; do
    [ -f "$p" ] && echo "  eips found at: $p"
done
echo
echo "Note: Amazon's eips can also draw images ('eips -g file x y') and is a"
echo "possible fallback, but its supported formats differ from fbink's."
