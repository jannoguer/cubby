#!/bin/sh
# Browse and restore snapshots. Run on the host from the directory holding shared/ and backups/.
#   restore.sh list [PATH]                 snapshots; with PATH, only those containing it, with mtime and size
#   restore.sh restore [-f] SNAPSHOT PATH  copy PATH from SNAPSHOT (or "latest") into shared/, owner fixed
# An existing shared/PATH is left alone unless -f is given.
set -eu

usage() {
    sed -n '3,5s/^# //p' "$0" >&2
    exit 2
}

[ -d shared ] && [ -d backups ] || { echo "ERROR: run from the directory holding shared/ and backups/." >&2; exit 1; }

check_path() {
    case "$1" in
        ''|/*|.|..|../*|*/..|*/../*) echo "ERROR: PATH must be relative to shared/, without '..'." >&2; exit 1 ;;
    esac
}

case "${1-}" in
list)
    p=${2-}
    [ -z "$p" ] || check_path "$p"
    for d in backups/????-??-??T??????Z; do
        [ -d "$d" ] || continue
        if [ -z "$p" ]; then
            echo "${d##*/}"
        elif [ -e "$d/$p" ]; then
            printf '%s  %s  %s\n' "${d##*/}" "$(stat -c %y "$d/$p" | cut -c1-19)" "$(du -sh "$d/$p" | cut -f1)"
        fi
    done
    ;;
restore)
    force=0
    if [ "${2-}" = -f ]; then force=1; shift; fi
    snap=${2-}; p=${3-}
    [ -n "$snap" ] && [ -n "$p" ] || usage
    check_path "$p"
    src="backups/$snap/$p"
    [ -e "$src" ] || { echo "ERROR: $src does not exist." >&2; exit 1; }
    if [ -e "shared/$p" ] && [ "$force" -eq 0 ]; then
        echo "ERROR: shared/$p exists; pass -f to replace it." >&2
        exit 1
    fi
    [ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo: the copy must be owned by uid 1000." >&2; exit 1; }
    # Parents made here must be usable by the sync user too.
    parent=shared
    dir=$(dirname "$p")
    if [ "$dir" != . ]; then
        set -f; IFS=/
        for c in $dir; do
            parent="$parent/$c"
            [ -d "$parent" ] || { mkdir "$parent"; chown 1000:1000 "$parent"; }
        done
        unset IFS; set +f
    fi
    rm -rf "shared/$p"
    cp -a "$src" "shared/$p"
    chown -R 1000:1000 "shared/$p"
    echo "Restored shared/$p from $snap."
    ;;
*) usage ;;
esac
