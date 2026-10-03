#!/bin/sh
# ============================================================================
#  Check that a GitHub repo will work as an update source.
#
#  Run this BEFORE turning on UPDATE_ON_START. It downloads the archive exactly
#  the way the device will, then verifies everything the updater requires:
#
#    * the URL codeload.github.com builds for that owner/repo/ref resolves
#    * the response really is a gzip archive and not an error page
#    * it extracts
#    * it contains device/config.sh and the other expected files
#    * every shell script inside passes `sh -n`
#
#  Usage:
#      sh tools/check-update-source.sh owner/repo [ref]
#      sh tools/check-update-source.sh owner/repo refs/tags/v1.0.0
#      sh tools/check-update-source.sh --url https://example.com/thing.tar.gz
#
#  NOTE: do not test this with a zip made by PowerShell's Compress-Archive. It
#  writes entries with BACKSLASH separators, which unzip rejects with
#  "appears to use backslashes as path separators". That is a quirk of that
#  tool, not of this check or of the updater. Build a .tar.gz with tar instead
#  (or just use a real GitHub archive, which is always a proper .tar.gz).
# ============================================================================

set -u

REPO=""
REF="main"
URL_OVERRIDE=""

case "${1:-}" in
    --url)
        URL_OVERRIDE="${2:-}"
        [ -n "$URL_OVERRIDE" ] || { echo "usage: $0 --url <archive-url>"; exit 2; }
        ;;
    '')
        echo "usage: $0 <owner/repo> [ref]   |   $0 --url <archive-url>"
        exit 2
        ;;
    *)
        REPO="$1"
        REF="${2:-main}"
        ;;
esac

if [ -n "$URL_OVERRIDE" ]; then
    URL="$URL_OVERRIDE"
else
    case "$REF" in
        refs/*) REFPATH="$REF" ;;
        *)      REFPATH="refs/heads/$REF" ;;
    esac
    URL="https://codeload.github.com/$REPO/tar.gz/$REFPATH"
fi

echo "url: $URL"
echo

TMP=$(mktemp -d 2>/dev/null || echo /tmp/updcheck-$$)
mkdir -p "$TMP" 2>/dev/null
ARCHIVE="$TMP/a.pkg"

# --- fetch -----------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
    echo "fetching with curl..."
    # -f is essential: on 404 it exits non-zero WITHOUT writing the body, so an
    # HTML error page can never be mistaken for an archive.
    if ! curl -fsSL --connect-timeout 15 --max-time 180 -o "$ARCHIVE" "$URL"; then
        echo "FAIL: download failed."
        echo "      Wrong owner/repo/ref, a private repo (needs UPDATE_TOKEN), or offline."
        rm -rf "$TMP"; exit 1
    fi
elif command -v wget >/dev/null 2>&1; then
    echo "fetching with wget..."
    if ! wget -q -O "$ARCHIVE" -T 180 "$URL"; then
        echo "FAIL: download failed."; rm -rf "$TMP"; exit 1
    fi
else
    echo "FAIL: neither curl nor wget available."; rm -rf "$TMP"; exit 1
fi

SIZE=$(wc -c < "$ARCHIVE" | tr -d ' ')
MAGIC=$(od -An -tx1 -N2 "$ARCHIVE" | tr -d ' \n')
echo "downloaded : $SIZE bytes"
echo "magic      : $MAGIC  (1f8b = gzip, 504b = zip)"

case "$MAGIC" in
    1f8b|504b) echo "archive    : looks valid" ;;
    *)
        echo "archive    : NOT an archive. First bytes:"
        head -c 200 "$ARCHIVE" | sed 's/^/             /'
        rm -rf "$TMP"; exit 1
        ;;
esac

# --- extract ---------------------------------------------------------------
# Errors are captured and shown, not swallowed. A silent extraction failure here
# would be indistinguishable from a bad archive.
EXTRACTED=0
EXTRACT_ERR=""
mkdir -p "$TMP/x"
if command -v tar >/dev/null 2>&1; then
    if EXTRACT_ERR=$(tar -xzf "$ARCHIVE" -C "$TMP/x" 2>&1); then
        EXTRACTED=1
    fi
fi
if [ "$EXTRACTED" != "1" ] && command -v unzip >/dev/null 2>&1; then
    if EXTRACT_ERR=$(unzip -o -q "$ARCHIVE" -d "$TMP/x" 2>&1); then
        EXTRACTED=1
    fi
fi
if [ "$EXTRACTED" != "1" ]; then
    echo "FAIL: could not extract the archive."
    echo "      location: $ARCHIVE"
    [ -n "$EXTRACT_ERR" ] && printf '%s\n' "$EXTRACT_ERR" | head -5 | sed 's/^/      /'
    echo "      (the device only needs tar + gzip, since GitHub serves .tar.gz;"
    echo "       a .zip needs unzip)"
    rm -rf "$TMP"; exit 1
fi

ROOT=""
for d in "$TMP/x"/*; do
    [ -d "$d" ] && ROOT="$d" && break
done
echo "top level  : $(basename "${ROOT:-<none>}")"
echo

# --- layout ----------------------------------------------------------------
# An archive is either the CODE repo (device/config.sh present) or an ART-ONLY
# repo (frame sets and nothing else). Both are legitimate sources -- for
# UPDATE_REPO and ART_URL respectively -- so identify which one this is rather
# than assuming code and rejecting a perfectly good art repo.
echo "=== layout ==="
KIND=""
if [ -f "$ROOT/device/config.sh" ]; then
    KIND="code"
    echo "  ok   device/config.sh found: this is the CODE repo"
else
    echo "  no device/config.sh -- checking whether this is an ART repo instead"
fi

if [ "$KIND" = "code" ]; then
    MISSING=""
    for f in dashboard.sh install.sh uninstall.sh config.sh lib/util.sh lib/render.sh; do
        [ -f "$ROOT/device/$f" ] || MISSING="$MISSING $f"
    done
    if [ -n "$MISSING" ]; then
        echo "  FAIL missing:$MISSING"
        rm -rf "$TMP"; exit 1
    fi
    echo "  ok   all expected files present"
fi

# --- syntax ----------------------------------------------------------------
# This is the check that stops a truncated or corrupt archive reaching a device.
BAD=0
if [ "$KIND" = "code" ]; then
    echo
    echo "=== shell syntax ==="
    COUNT=0
    for s in "$ROOT"/device/*.sh "$ROOT"/device/lib/*.sh "$ROOT"/device/kual/bin/*.sh; do
        [ -f "$s" ] || continue
        COUNT=$((COUNT + 1))
        if sh -n "$s" 2>/dev/null; then
            printf '  ok   %s\n' "$(basename "$s")"
        else
            printf '  FAIL %s\n' "$(basename "$s")"
            sh -n "$s" 2>&1 | head -3 | sed 's/^/         /'
            BAD=1
        fi
    done
    echo "  checked $COUNT script(s)"
fi

# --- artwork ---------------------------------------------------------------
# Frame sets can sit at the top level (an art-only repo) or under artwork/ (a
# full project repo), and either may be inside one wrapping directory, which is
# how GitHub names an archive. The base list below deliberately does not overlap,
# so a set is never counted twice.
echo
echo "=== artwork ==="
FRAMES=0
SETS=""
for base in "$ROOT" "$ROOT/artwork" "$ROOT"/*/artwork; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        n=$(ls "$d"frame_*.png 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -ge 2 ] || continue
        printf '  %-22s %s frames\n' "$(basename "$d")" "$n"
        FRAMES=$((FRAMES + 1))
        SETS="$SETS $(basename "$d")"
    done
done
if [ "$FRAMES" -gt 0 ]; then
    echo "  $FRAMES usable frame set(s):$SETS"
else
    echo "  (no frame sets found)"
fi

# An archive with neither code nor art is useless to the dashboard.
if [ -z "$KIND" ] && [ "$FRAMES" -eq 0 ]; then
    echo
    echo "  FAIL this archive has neither device/config.sh nor any frame set."
    echo "       Found at the top level:"
    ls -1 "$ROOT" 2>/dev/null | head -20 | sed 's/^/         /'
    rm -rf "$TMP"; exit 1
fi
if [ -z "$KIND" ]; then
    KIND="art"
    echo "  -> this is an ART-ONLY repo"
fi

rm -rf "$TMP"

echo
if [ "$BAD" = "1" ]; then
    echo "RESULT: FAILED -- syntax errors. The updater would reject this."
    exit 1
fi
if [ "$KIND" = "code" ]; then
    echo "RESULT: OK -- this is a CODE repo. Point UPDATE_REPO at it, or UPDATE_URL"
    echo "        at the archive URL above."
else
    echo "RESULT: OK -- this is an ART-ONLY repo, which is what ART_URL wants."
    echo "        Set ART_URL=\"$URL\" and ART_ON_START=1."
fi
exit 0
