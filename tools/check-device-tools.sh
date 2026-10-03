#!/bin/sh
# ============================================================================
#  Report which download / archive tools the device has.
#
#  A self-update has to fetch an archive and unpack it, so what is available
#  decides the format: a .tar.gz needs tar + gzip, a .zip needs unzip, and if
#  neither exists the update has to fall back to fetching individual files.
#
#  Run on the Kindle, or from Git Bash on Windows (KINDLE_US=/f).
# ============================================================================

KINDLE_US="${KINDLE_US:-/mnt/us}"
[ -d "$KINDLE_US" ] || KINDLE_US=/f
[ -d "$KINDLE_US" ] || { echo "cannot find the Kindle user partition; set KINDLE_US"; exit 1; }

echo "user partition: $KINDLE_US"
echo

echo "=== tools on PATH (this shell) ==="
for t in curl wget tar gzip gunzip unzip busybox python python3 od dd awk sed; do
    _p=$(command -v "$t" 2>/dev/null)
    if [ -n "$_p" ]; then
        printf '  %-10s %s\n' "$t" "$_p"
    else
        printf '  %-10s %s\n' "$t" "(not on PATH)"
    fi
done

echo
echo "=== the same tools on the device filesystem ==="
# PATH from a KUAL-launched script is not this shell's PATH, so also look in the
# usual places directly.
for d in /usr/bin /bin /usr/sbin /usr/local/bin; do
    for t in curl wget tar gzip gunzip unzip; do
        [ -f "$d/$t" ] && printf '  %-24s %s\n' "$d/$t" "present"
    done
done
echo "  (nothing above means they are busybox applets, not separate files)"

echo
echo "=== busybox applets, if busybox exists ==="
for b in busybox /bin/busybox /usr/bin/busybox; do
    if [ -x "$b" ] 2>/dev/null || command -v "$b" >/dev/null 2>&1; then
        echo "  $b:"
        "$b" --list 2>/dev/null | tr '\n' ' ' | tr -s ' ' | cut -c1-400
        echo
        break
    fi
done

echo
echo "=== copies bundled inside KOReader (usable even without PATH) ==="
for t in tar gzip gunzip zsync2 spinning_zsync; do
    if [ -f "$KINDLE_US/koreader/$t" ]; then
        printf '  %-40s %s bytes\n' "$KINDLE_US/koreader/$t" "$(wc -c < "$KINDLE_US/koreader/$t" | tr -d ' ')"
    fi
done
ls "$KINDLE_US/koreader" 2>/dev/null | grep -iE 'zip|curl|wget|unzip' | sed 's/^/  koreader\//'

echo
echo "=== does this curl speak https? ==="
for c in "$KINDLE_US/koreader/curl" /usr/bin/curl /bin/curl; do
    [ -x "$c" ] || [ -f "$c" ] || continue
    _v=$("$c" --version 2>/dev/null | head -n 1)
    echo "  $c: ${_v:-<no version output>}"
    _ssl=$("$c" --version 2>/dev/null | grep -io 'openssl/[0-9.]*\|schannel\|gnutls\|nss' | head -n 1)
    echo "      TLS backend: ${_ssl:-unknown}"
done

echo
echo "=== conclusion ==="
_have_tar=0
for b in busybox /bin/busybox /usr/bin/busybox; do
    if "$b" --list 2>/dev/null | grep -qw tar; then _have_tar=1; break; fi
done
command -v tar >/dev/null 2>&1 && _have_tar=1
if [ "$_have_tar" = "1" ]; then
    echo "  tar is available -> a .tar.gz archive can be unpacked (preferred: one"
    echo "  HTTP request, and codeload.github.com serves it directly)."
else
    echo "  no tar found -> the update must fall back to fetching files individually"
    echo "  from raw.githubusercontent.com."
fi
