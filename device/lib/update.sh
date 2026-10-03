#!/bin/sh
# ============================================================================
#  Self-update from a GitHub archive.
#
#  One HTTP request for the whole tree. codeload.github.com serves a .tar.gz
#  directly, so there is no need to fetch file-by-file (which would also leave
#  the install half-updated if one file failed mid-way).
#
#  SAFETY, in order of importance. Auto-updating executable shell code from the
#  network is the riskiest thing in this project, so:
#
#   1. NOTHING is written until the download has been fully validated: it must be
#      non-empty, carry the archive magic bytes, extract cleanly, contain every
#      expected file, and every shell script must pass `sh -n`. A truncated
#      download or a 404 HTML error page therefore cannot replace working code.
#   2. The current install is backed up first and restored if applying fails.
#   3. config.sh, state/ and log/ are never overwritten, so settings and runtime
#      data survive.
#   4. Files are replaced by writing a temporary then renaming. `mv` within a
#      directory is atomic, and a running shell keeps reading the old inode it
#      already has open, so a live daemon can never read a half-written script.
#      (In-place truncate-and-write is what corrupts a running script.)
# ============================================================================

# Files that must exist in any downloaded tree, as a sanity check that we got
# this project and not something else.
UPDATE_EXPECTED="dashboard.sh install.sh uninstall.sh config.sh lib/util.sh lib/render.sh"

# Never copy these over the installed tree.
UPDATE_SKIP="|config.sh|state|log|animations"

update_tmp() {
    if [ -n "${UPDATE_TMPDIR:-}" ]; then
        printf '%s' "$UPDATE_TMPDIR"
        return 0
    fi
    # /var/tmp is tmpfs on the Kindle and is the right place there. Fall back to
    # $TMPDIR and /tmp so this still works on a firmware where /var/tmp is not
    # writable -- and so the whole fetch path can be exercised off-device. Without
    # a fallback the failure is just "cannot create /var/tmp/...", which says
    # nothing about what to do.
    for _d in /var/tmp "${TMPDIR:-}" /tmp; do
        [ -n "$_d" ] || continue
        if [ -d "$_d" ] && [ -w "$_d" ]; then
            printf '%s/kdash-update' "$_d"
            return 0
        fi
    done
    printf '%s' "/var/tmp/kdash-update"
}

# Download the archive. curl's -f is what stops an HTTP error page from being
# saved as if it were the archive: on 404 it exits non-zero WITHOUT writing the
# body. The token, if any, is passed as a header and never logged.
#
# !! POSIX sh has NO `local`. This function used to assign `_url` and `_dest`,
# which are therefore GLOBAL -- and art_run() uses `_dest` for its INSTALL
# DESTINATION. So the download clobbered it to the downloaded file's path, and the
# install then tried to write into a file, failed silently, and reported "no
# usable frame sets". Use the positional parameters instead: they are saved and
# restored across calls, so a callee cannot damage its caller's state.
update_fetch() {  # $1=url $2=dest
    if [ -n "${CURL_BIN:-}" ]; then
        if [ -n "${UPDATE_TOKEN:-}" ]; then
            "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 240 \
                -H "Authorization: Bearer $UPDATE_TOKEN" \
                -o "$2" "$1" 2>>"$LOG_FILE"
        else
            "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 240 \
                -o "$2" "$1" 2>>"$LOG_FILE"
        fi
        return $?
    fi
    if [ -n "${WGET_BIN:-}" ]; then
        "$WGET_BIN" -q -O "$2" -T 240 "$1" 2>>"$LOG_FILE"
        return $?
    fi
    log "update: neither curl nor wget available"
    return 1
}

# Turn UPDATE_REF into a ref path. Accepts "main" (branch) or a full
# "refs/heads/main" / "refs/tags/v1.0" for anything else.
update_ref_path() {
    _r="${UPDATE_REF:-refs/heads/main}"
    case "$_r" in
        refs/*) printf '%s' "$_r" ;;
        *)      printf 'refs/heads/%s' "$_r" ;;
    esac
}

# The archive URL. UPDATE_URL wins outright so this works against GitLab, a
# release asset, or any plain file server, not just GitHub.
update_archive_url() {
    if [ -n "${UPDATE_URL:-}" ]; then
        printf '%s' "$UPDATE_URL"
        return 0
    fi
    if [ -z "${UPDATE_REPO:-}" ]; then
        printf ''
        return 1
    fi
    # Catch the shipped placeholder. Without this the updater cheerfully requests
    # codeload.github.com/owner/repo/... and reports a bare "HTTP 404", which says
    # nothing about the real problem: config.sh was never pointed at a repository.
    case "$UPDATE_REPO" in
        owner/repo|you/your-repo|your-user/your-repo)
            update_placeholder_msg
            printf ''
            return 1
            ;;
    esac
    printf 'https://codeload.github.com/%s/tar.gz/%s' \
        "$UPDATE_REPO" "$(update_ref_path)"
    return 0
}

# Why the update cannot run, in terms the reader can act on.
update_placeholder_msg() {
    log "update: UPDATE_REPO is still the placeholder '$UPDATE_REPO'"
    log "update: the code updater needs a repo containing device/config.sh --"
    log "update: the artwork repo is NOT usable here (it is art-only)"
    log "update: set UPDATE_REPO=\"<owner>/<repo>\" in config.sh, or UPDATE_URL"
}

# Identify the archive by its magic bytes rather than trusting the filename.
# Uses `head -c` + od rather than `od -N`, because busybox's od does not
# reliably support -N and a missing flag here would silently misread every file.
update_archive_kind() {
    _a="$1"
    [ -s "$_a" ] || { printf ''; return 0; }
    _magic=$(head -c 2 "$_a" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    case "$_magic" in
        1f8b) printf 'gzip' ;;
        504b) printf 'zip' ;;
        *)    printf '' ;;
    esac
}

# Which extraction tool to use, decided by running them once.
UPDATE_UNTAR=""
UPDATE_UNZIP=""

update_find_extractors() {
    if [ -z "$UPDATE_UNTAR" ]; then
        # $FBINK-style search: the firmware copy first, then KOReader's bundled
        # one, since the device root cannot be enumerated ahead of time.
        for _t in tar /usr/bin/tar /bin/tar /mnt/us/koreader/tar; do
            if "$_t" --version >/dev/null 2>&1 || "$_t" -cf /dev/null /dev/null >/dev/null 2>&1; then
                UPDATE_UNTAR="$_t"
                break
            fi
        done
    fi
    if [ -z "$UPDATE_UNZIP" ]; then
        for _u in unzip /usr/bin/unzip /bin/unzip; do
            if "$_u" -v >/dev/null 2>&1; then
                UPDATE_UNZIP="$_u"
                break
            fi
        done
    fi
    return 0
}

update_extract() {  # $1=archive $2=destdir
    _kind=$(update_archive_kind "$1")
    mkdir -p "$2" 2>/dev/null || return 1
    update_find_extractors
    case "$_kind" in
        gzip)
            if [ -n "$UPDATE_UNTAR" ]; then
                "$UPDATE_UNTAR" -xzf "$1" -C "$2" 2>>"$LOG_FILE" && return 0
            fi
            if command -v gzip >/dev/null 2>&1 && [ -n "$UPDATE_UNTAR" ]; then
                gzip -dc "$1" 2>>"$LOG_FILE" | "$UPDATE_UNTAR" -xf - -C "$2" 2>>"$LOG_FILE" && return 0
            fi
            log "update: cannot extract a .tar.gz (no usable tar/gzip)"
            return 1
            ;;
        zip)
            [ -n "$UPDATE_UNZIP" ] || { log "update: cannot extract a .zip (no unzip)"; return 1; }
            "$UPDATE_UNZIP" -o -q "$1" -d "$2" 2>>"$LOG_FILE" && return 0
            return 1
            ;;
        *)
            log "update: download is not an archive (wrong URL, or an error page)"
            return 1
            ;;
    esac
}

# GitHub archives wrap everything in one directory whose name varies by ref, so
# find the tree by looking for a known file rather than guessing the name.
update_find_root() {  # $1=extract dir
    [ -d "$1" ] || return 1
    for _d in "$1"/*; do
        [ -d "$_d" ] || continue
        if [ -f "$_d/device/config.sh" ]; then
            printf '%s' "$_d"
            return 0
        fi
    done
    return 1
}

# Everything that has to be true before any file is replaced.
update_validate() {  # $1=tree root
    _root="$1"
    [ -d "$_root/device" ] || { log "update: archive has no device/ directory"; return 1; }

    for _f in $UPDATE_EXPECTED; do
        if [ ! -f "$_root/device/$_f" ]; then
            log "update: archive is missing device/$_f"
            return 1
        fi
    done

    # Syntax-check every script. This is the check that actually stops a corrupt
    # or truncated download from bricking the install.
    _bad=0
    for _s in "$_root"/device/*.sh "$_root"/device/lib/*.sh "$_root"/device/kual/bin/*.sh; do
        [ -f "$_s" ] || continue
        if ! sh -n "$_s" 2>>"$LOG_FILE"; then
            log "update: syntax error in $(basename "$_s") -- rejecting"
            _bad=1
        fi
    done
    [ "$_bad" = "0" ] || return 1
    return 0
}

# Recursive copy that skips UPDATE_SKIP at the top level only, and installs each
# file via a temporary + rename so a running process never sees a partial write.
#
# !! POSIX sh has NO `local`. The first version of this function used named
# variables (_src/_dst/_skip), which are therefore GLOBAL: the recursive call
# into a subdirectory clobbered the parent's destination, and every later
# iteration wrote into the wrong directory -- scattering the update across the
# install. Function POSITIONAL PARAMETERS are saved and restored across calls, so
# they are the only safe place to keep recursion state. Do not "tidy" these back
# into named variables.
update_copy_tree() {  # $1=src $2=dst $3=top-level skip list
    [ -d "$1" ] || return 0
    mkdir -p "$2" 2>/dev/null

    for _item in "$1"/*; do
        [ -e "$_item" ] || continue
        _base=$(basename "$_item")
        case "$3" in *"|$_base|"*) continue ;; esac
        if [ -d "$_item" ]; then
            update_copy_tree "$_item" "$2/$_base" "" || return 1
        else
            if cp "$_item" "$2/$_base.new" 2>/dev/null; then
                if mv -f "$2/$_base.new" "$2/$_base" 2>/dev/null; then
                    case "$_base" in *.sh) chmod 0755 "$2/$_base" 2>/dev/null ;; esac
                else
                    rm -f "$2/$_base.new" 2>/dev/null
                    return 1
                fi
            else
                return 1
            fi
        fi
    done
    return 0
}

# Apply a validated tree over the live install, with a backup for rollback.
update_apply() {  # $1=tree root
    _root="$1"
    _backup="$(update_tmp)-backup"
    rm -rf "$_backup" 2>/dev/null
    mkdir -p "$_backup" 2>/dev/null

    # 1. back up what we are about to replace
    if [ -d "$DASH_DIR" ]; then
        cp -r "$DASH_DIR" "$_backup/dashboard" 2>/dev/null
    fi
    if [ -d /mnt/us/extensions/dashboard ]; then
        cp -r /mnt/us/extensions/dashboard "$_backup/extensions-dashboard" 2>/dev/null
    fi

    # 2. code. config.sh/state/log are skipped so settings and data survive.
    if ! update_copy_tree "$_root/device" "$DASH_DIR" "$UPDATE_SKIP"; then
        log "update: failed writing device files, rolling back"
        update_rollback "$_backup"
        return 1
    fi

    # 3. artwork (frames change often, so they are part of the update). Note the
    #    repo directory is artwork/ while the device directory is animations/.
    if [ -d "$_root/artwork" ]; then
        update_copy_tree "$_root/artwork" "$DASH_DIR/animations" "" \
            || log "update: WARNING could not refresh artwork (code is fine)"
    fi

    # 4. the KUAL extension
    if [ -d "$_root/device/kual" ] && [ -d /mnt/us/extensions/dashboard ]; then
        update_copy_tree "$_root/device/kual" /mnt/us/extensions/dashboard "" \
            || log "update: WARNING could not refresh the KUAL extension"
        chmod 0755 /mnt/us/extensions/dashboard/bin/*.sh 2>/dev/null
    fi

    log "update: applied successfully (backup at $_backup)"
    return 0
}

update_rollback() {  # $1=backup dir
    _backup="$1"
    log "update: rolling back from $_backup"
    if [ -d "$_backup/dashboard" ]; then
        update_copy_tree "$_backup/dashboard" "$DASH_DIR" "" \
            || log "update: ROLLBACK FAILED -- reinstall with tools/deploy.ps1"
    fi
    if [ -d "$_backup/extensions-dashboard" ]; then
        update_copy_tree "$_backup/extensions-dashboard" /mnt/us/extensions/dashboard "" \
            || log "update: ROLLBACK of extension failed"
    fi
    return 0
}

# Fetch + validate + apply. No restart; the caller decides that.
update_run() {
    _url=$(update_archive_url) || { log "update: no UPDATE_REPO or UPDATE_URL set"; return 1; }
    [ -n "$_url" ] || { log "update: no UPDATE_REPO or UPDATE_URL set"; return 1; }

    _tmp=$(update_tmp)
    rm -rf "$_tmp" 2>/dev/null
    mkdir -p "$_tmp" 2>/dev/null || { log "update: cannot create $_tmp"; return 1; }

    _archive="$_tmp/update.pkg"
    log "update: fetching $_url"
    if ! update_fetch "$_url" "$_archive"; then
        log "update: download failed (offline, or a bad URL/ref)"
        rm -rf "$_tmp" 2>/dev/null
        return 1
    fi

    _kind=$(update_archive_kind "$_archive")
    _size=$(wc -c < "$_archive" 2>/dev/null | tr -d ' ')
    log "update: downloaded ${_size:-0} bytes, archive kind=${_kind:-unknown}"
    if [ -z "$_kind" ]; then
        log "update: not a usable archive -- keeping the current install"
        rm -rf "$_tmp" 2>/dev/null
        return 1
    fi

    if ! update_extract "$_archive" "$_tmp/x"; then
        log "update: extraction failed -- keeping the current install"
        rm -rf "$_tmp" 2>/dev/null
        return 1
    fi

    _root=$(update_find_root "$_tmp/x") || {
        log "update: no device/ tree inside the archive -- wrong repo?"
        rm -rf "$_tmp" 2>/dev/null
        return 1
    }

    if ! update_validate "$_root"; then
        log "update: validation failed -- keeping the current install"
        rm -rf "$_tmp" 2>/dev/null
        return 1
    fi

    if ! update_apply "$_root"; then
        rm -rf "$_tmp" 2>/dev/null
        return 1
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null
    date +%s > "$STATE_DIR/last-update" 2>/dev/null
    log "update: done"
    return 0
}

# Is a start-time update wanted right now?
update_due() {
    [ "${UPDATE_ON_START:-0}" = "1" ] || return 1
    _iv="${UPDATE_MIN_INTERVAL:-0}"
    is_int "$_iv" || _iv=0
    [ "$_iv" -le 0 ] && return 0        # 0 = check on every start
    _f="$STATE_DIR/last-update"
    [ -r "$_f" ] || return 0
    _last=$(cat "$_f" 2>/dev/null | tr -d ' \r\n')
    is_int "$_last" || return 0
    [ $(( $(date +%s) - _last )) -ge "$_iv" ]
}

# ============================================================================
#  ARTWORK
#
#  Art is fetched separately from the code on purpose. The code updater refuses
#  anything that does not look like this whole project (device/config.sh and so
#  on), so an artwork-only archive would be rejected by it. Artwork has its own
#  URL and its own looser validation: any directory of f_*.png frames counts.
#
#  Nothing is installed until the frames are proven to be real PNGs, and a failed
#  fetch leaves the frames already on the device untouched -- so a bad URL can
#  never leave the panel with no animation.
# ============================================================================

# Destination for installed sets. Must match ANIM_DIR_* in the config.
ART_DEST_DEFAULT="/mnt/us/dashboard/animations"

art_tmp() {
    printf '%s' "$(update_tmp)-art"
}

art_dest() {
    printf '%s' "${ART_DEST:-$ART_DEST_DEFAULT}"
}

# PNG dimensions straight out of IHDR: bytes 16-19 width, 20-23 height, big
# endian. Used to warn when a set does not match the size its mode expects.
art_png_size() {
    _f="$1"
    [ -f "$_f" ] || return 1
    head -c 24 "$_f" 2>/dev/null | od -An -tu1 2>/dev/null | tr -s ' \n' ' ' | awk '
        { if (NF < 24) exit 1
          w = $17 * 16777216 + $18 * 65536 + $19 * 256 + $20
          h = $21 * 16777216 + $22 * 65536 + $23 * 256 + $24
          printf "%dx%d", w, h }'
}

# Echoes the frame count if the directory is a usable set, else fails.
art_validate_dir() {
    _d="$1"
    _n=0
    for _f in "$_d"/${ANIM_FRAME_GLOB:-frame_*.png}; do
        [ -f "$_f" ] || continue
        _n=$(( _n + 1 ))
    done
    [ "$_n" -ge 2 ] || return 1
    for _f in "$_d"/${ANIM_FRAME_GLOB:-frame_*.png}; do
        [ -f "$_f" ] || continue
        _m=$(head -c 8 "$_f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
        if [ "$_m" != "89504e470d0a1a0a" ]; then
            log "art: $(basename "$_f") is not a PNG (magic '${_m:-empty}')"
            return 1
        fi
    done
    printf '%s' "$_n"
}

# Soft check: warn, do not fail. A mismatched size still draws, it may just be
# cropped or off-centre.
art_size_check() {
    _name="$1"; _dir="$2"
    case "$_name" in
        # One set, drawn fullscreen, so one expected size.
        bird) _want="420x320" ;;
        *)    return 0 ;;
    esac
    for _f in "$_dir"/${ANIM_FRAME_GLOB:-frame_*.png}; do
        [ -f "$_f" ] || continue
        _got=$(art_png_size "$_f")
        if [ -n "$_got" ] && [ "$_got" != "$_want" ]; then
            log "art: WARNING set '$_name' is $_got but $_want is what $_name expects"
        fi
        break
    done
    return 0
}

art_install_tree() {  # $1 = extracted root, $2 = destination, $3 = only this set (optional)
    _root="$1"; _dest="$2"; _only="${3:-}"
    # Find the artwork directory. An art-only archive is usually ONE wrapping
    # directory around artwork/, so check a level down as well as the top --
    # otherwise a perfectly good art repo looks empty.
    _search=""
    for _cand in "$_root/artwork" "$_root"/*/artwork; do
        [ -d "$_cand" ] && { _search="$_cand"; break; }
    done
    [ -n "$_search" ] || _search="$_root"

    _found=0
    for _d in "$_search"/*; do
        [ -d "$_d" ] || continue
        _name=$(basename "$_d")
        # With many artworks in one repo, "only_active" means we keep just the one
        # being played rather than copying thousands of sets to the device.
        if [ -n "$_only" ] && [ "$_name" != "$_only" ]; then
            continue
        fi
        _n=$(art_validate_dir "$_d") || continue
        log "art: installing set '$_name' ($_n frames)"
        mkdir -p "$_dest/$_name" 2>/dev/null
        if update_copy_tree "$_d" "$_dest/$_name" ""; then
            art_size_check "$_name" "$_dest/$_name"
            _found=$(( _found + 1 ))
        else
            log "art: WARNING could not write set '$_name'"
        fi
    done

    # Nested one level deeper, in case someone uploads artwork/<set>/<set>/
    if [ "$_found" = "0" ]; then
        for _d in "$_search"/*/*; do
            [ -d "$_d" ] || continue
            _name=$(basename "$_d")
            if [ -n "$_only" ] && [ "$_name" != "$_only" ]; then
                continue
            fi
            _n=$(art_validate_dir "$_d") || continue
            log "art: installing nested set '$_name' ($_n frames)"
            mkdir -p "$_dest/$_name" 2>/dev/null
            update_copy_tree "$_d" "$_dest/$_name" "" && _found=$(( _found + 1 ))
        done
    fi

    [ "$_found" -gt 0 ]
}

# Fallback: fetch frames one at a time from a base URL, stopping at the first
# missing frame. Frames land in a scratch dir first and are only installed once
# the whole set validates, so a half-downloaded set never replaces a good one.
art_install_raw() {  # $1 = base url, $2 = destination, $3 = set name(s)
    _base="$1"; _dest="$2"; _want="${3:-bird}"
    _work="$(art_tmp)-raw"
    rm -rf "$_work" 2>/dev/null
    mkdir -p "$_work" 2>/dev/null

    _found=0
    for _set in $_want; do
        _sd="$_work/$_set"
        mkdir -p "$_sd" 2>/dev/null
        _i=0
        while [ "$_i" -lt "${ART_MAX_FRAMES:-24}" ]; do
            _name=$(printf 'frame_%03d.png' "$_i")
            if http_get "$_base/$_set/$_name" > "$_sd/$_name" 2>/dev/null && [ -s "$_sd/$_name" ]; then
                _i=$(( _i + 1 ))
            else
                rm -f "$_sd/$_name" 2>/dev/null
                break
            fi
        done
        _n=$(art_validate_dir "$_sd") || {
            log "art: no usable frames for '$_set' at $_base/$_set"
            continue
        }
        log "art: fetched $_n frames for '$_set' via raw base"
        mkdir -p "$_dest/$_set" 2>/dev/null
        update_copy_tree "$_sd" "$_dest/$_set" "" && {
            art_size_check "$_set" "$_dest/$_set"
            _found=$(( _found + 1 ))
        }
    done
    rm -rf "$_work" 2>/dev/null
    [ "$_found" -gt 0 ]
}

# --- what the artwork repo says ---------------------------------------------
# A repo can declare which artwork is current, so changing it is a one-line edit
# on GitHub rather than tapping through a list on the device -- which stops being
# practical well before "thousands". The file is optional: without it the device's
# own choice is used.
#
#   config.json   { "active": "<folder-name>", "only_active": false }
#
# A plain text file containing just the name also works, so it is hard to get
# wrong in GitHub's web editor.
ART_CONFIG_NAME="config.json"

# Locate the repo config inside an extracted tree.
art_find_config() {  # $1 = tree root
    for _c in "$1/$ART_CONFIG_NAME" "$1"/*/"$ART_CONFIG_NAME"; do
        [ -f "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    return 1
}

# The declared active set, or empty if the config does not name one.
art_config_active() {  # $1 = config file
    _flat=$(tr -d '\n\r' < "$1" 2>/dev/null)
    _a=$(json_str "$_flat" active)
    if [ -z "$_a" ]; then
        # Tolerate a bare name with no JSON at all: take the first line.
        _a=$(head -n 1 "$1" 2>/dev/null | tr -d ' \r\n')
        case "$_a" in *'{'*|*'"'*|*':'*) _a="" ;; esac
    fi
    printf '%s' "$_a"
}

# True when the config asks for only the active set to be installed.
art_config_only_active() {  # $1 = config file
    _flat=$(tr -d '\n\r' < "$1" 2>/dev/null)
    case "$_flat" in
        *'"only_active"'*true*) return 0 ;;
    esac
    return 1
}

# Record what the repo declares, so active_set() can honour it cheaply.
art_record_declared() {  # $1 = declared name, $2 = destination
    if [ -n "$1" ]; then
        # Cheap presence check only. art_install_tree has ALREADY fully validated
        # this set (real PNGs, at least two frames), so re-validating here would
        # duplicate that work and needlessly make this depend on PNG magic.
        _cnt=0
        for _f in "$2/$1"/${ANIM_FRAME_GLOB:-frame_*.png}; do
            [ -f "$_f" ] || continue
            _cnt=$(( _cnt + 1 ))
        done
        if [ -d "$2/$1" ] && [ "$_cnt" -ge 2 ]; then
            mkdir -p "$STATE_DIR" 2>/dev/null
            printf '%s\n' "$1" > "$STATE_DIR/repo-active"
            log "art: repo declares active='$1'"
            return 0
        fi
        log "art: WARNING config names '$1' but that set is not installed; ignoring it"
    fi
    # Clear any previous declaration: a stale name would otherwise keep winning
    # even after the repo stopped naming one.
    rm -f "$STATE_DIR/repo-active" 2>/dev/null
    return 1
}

# Fetch and install artwork. Never fatal: on failure the existing frames stay.
art_run() {
    _dest=$(art_dest)
    _tmp=$(art_tmp)

    if [ -n "${ART_URL:-}" ]; then
        rm -rf "$_tmp" 2>/dev/null
        mkdir -p "$_tmp" 2>/dev/null || { log "art: cannot create $_tmp"; return 1; }
        _archive="$_tmp/art.pkg"
        log "art: fetching ${ART_URL}"
        if ! update_fetch "$ART_URL" "$_archive"; then
            log "art: download failed -- keeping the frames already installed"
            rm -rf "$_tmp" 2>/dev/null
            return 1
        fi
        if [ -z "$(update_archive_kind "$_archive")" ]; then
            log "art: not a usable archive (wrong URL, or an error page) -- keeping existing frames"
            rm -rf "$_tmp" 2>/dev/null
            return 1
        fi
        if ! update_extract "$_archive" "$_tmp/x"; then
            log "art: extraction failed -- keeping existing frames"
            rm -rf "$_tmp" 2>/dev/null
            return 1
        fi
        # Locate the tree. A code archive has device/config.sh; an art-only
        # archive has no such marker and GitHub wraps the contents in ONE
        # directory, so descend into it. Without this, sets are only found by the
        # one-level-deep fallback inside art_install_tree, which logs confusingly
        # as "nested set" and cannot see a deeper structure.
        _root=$(update_find_root "$_tmp/x")
        if [ -z "$_root" ]; then
            for _cand in "$_tmp/x"/*; do
                [ -d "$_cand" ] && { _root="$_cand"; break; }
            done
        fi
        [ -n "$_root" ] || _root="$_tmp/x"

        # Read the repo's declaration BEFORE installing, so "only_active" can
        # restrict what gets copied.
        _declared=""
        _only=""
        if _cfg=$(art_find_config "$_root"); then
            _declared=$(art_config_active "$_cfg")
            art_config_only_active "$_cfg" && _only="$_declared"
        fi

        if art_install_tree "$_root" "$_dest" "$_only"; then
            art_record_declared "$_declared" "$_dest"
            log "art: installed into $_dest"
            mkdir -p "$STATE_DIR" 2>/dev/null
            date +%s > "$STATE_DIR/last-art" 2>/dev/null
            rm -rf "$_tmp" 2>/dev/null
            return 0
        fi
        log "art: no usable frame sets in the archive -- keeping existing frames"
        rm -rf "$_tmp" 2>/dev/null
        return 1
    fi

    if [ -n "${ART_RAW_BASE:-}" ]; then
        # Raw mode fetches frames one at a time, so it must know WHICH set to get.
        # Read it from the repo config, falling back to the configured default.
        # This is the scalable path for a repo holding many artworks: only the
        # frames actually played are downloaded at all.
        _raw_set=""
        _cfgtext=$(http_get "$ART_RAW_BASE/$ART_CONFIG_NAME" 2>/dev/null)
        if [ -n "$_cfgtext" ]; then
            _flat=$(printf '%s' "$_cfgtext" | tr -d '\n\r')
            _raw_set=$(json_str "$_flat" active)
        fi
        [ -n "$_raw_set" ] || _raw_set="${ANIM_SET:-bird}"
        if art_install_raw "$ART_RAW_BASE" "$_dest" "$_raw_set"; then
            art_record_declared "$_raw_set" "$_dest"
            log "art: installed from raw base into $_dest"
            mkdir -p "$STATE_DIR" 2>/dev/null
            date +%s > "$STATE_DIR/last-art" 2>/dev/null
            return 0
        fi
        log "art: nothing usable at $ART_RAW_BASE -- keeping existing frames"
        return 1
    fi

    log "art: neither ART_URL nor ART_RAW_BASE is set"
    return 1
}

art_due() {
    [ "${ART_ON_START:-0}" = "1" ] || return 1
    [ -n "${ART_URL:-}" ] || [ -n "${ART_RAW_BASE:-}" ] || return 1
    _iv="${ART_MIN_INTERVAL:-0}"
    is_int "$_iv" || _iv=0
    [ "$_iv" -le 0 ] && return 0
    _f="$STATE_DIR/last-art"
    [ -r "$_f" ] || return 0
    _last=$(cat "$_f" 2>/dev/null | tr -d ' \r\n')
    is_int "$_last" || return 0
    [ $(( $(date +%s) - _last )) -ge "$_iv" ]
}
