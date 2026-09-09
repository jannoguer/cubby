#!/bin/sh
# Browse and restore snapshots. Run on the host from the directory holding shared/ and backups/.
# A restore pauses the cubby container while it copies; after a hard kill, docker unpause cubby.
#   restore.sh list [PATH]                 snapshots; with PATH, only those containing it, with mtime and size
#   restore.sh restore [-f] SNAPSHOT PATH  copy PATH from SNAPSHOT (or "latest") into shared/, owner fixed
# An existing shared/PATH is left alone unless -f is given.
set -eu

usage() {
    sed -n '4,6s/^# //p' "$0" >&2
    exit 2
}

[ -d shared ] && [ -d backups ] || { echo "ERROR: run from the directory holding shared/ and backups/." >&2; exit 1; }

check_path() {
    case "$1" in
        ''|/*|.|..|../*|*/..|*/../*) echo "ERROR: PATH must be relative to shared/, without '..'." >&2; exit 1 ;;
    esac
}

# A symlink planted by a client in place of a directory would send the root
# writes below anywhere on the host. Fails on any symlinked component of DIR under BASE.
check_dirs() {
    base=$1
    set -f; IFS=/
    for c in $2; do
        base="$base/$c"
        [ -L "$base" ] && { echo "ERROR: $base is a symlink; refusing to go through it." >&2; exit 1; }
    done
    unset IFS; set +f
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
    case "$snap" in */*|.|..) echo "ERROR: SNAPSHOT must be a snapshot name or 'latest'." >&2; exit 1 ;; esac
    check_path "$p"
    case "$p" in .cubby|.cubby/*) echo "ERROR: .cubby is rebuilt by the server at start; restart the cubby container instead." >&2; exit 1 ;; esac
    [ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo: the copy must be owned by uid 1000." >&2; exit 1; }
    dir=$(dirname "$p")
    [ "$dir" = . ] && dir=""
    # A live client could swap a parent for a symlink between the checks and
    # the copy: freeze the container meanwhile.
    paused=0
    stage="backups/.restore-$$"
    cleanup() {
        rm -rf "$stage"
        [ "$paused" -eq 0 ] || docker unpause cubby > /dev/null
    }
    trap cleanup EXIT
    if command -v docker > /dev/null 2>&1; then
        if [ "$(docker inspect -f '{{.State.Status}}' cubby 2>/dev/null)" = running ]; then
            docker pause cubby > /dev/null && paused=1
        fi
    else
        echo "WARNING: docker not found; the sync stays live during the restore." >&2
    fi
    check_dirs "backups/$snap" "$dir"
    check_dirs shared "$dir"
    src="backups/$snap/$p"
    [ -e "$src" ] || { echo "ERROR: $src does not exist." >&2; exit 1; }
    if [ -e "shared/$p" ] && [ "$force" -eq 0 ]; then
        echo "ERROR: shared/$p exists; pass -f to replace it." >&2
        exit 1
    fi
    # Parents made here must be usable by the sync user too.
    parent=shared
    set -f; IFS=/
    for c in $dir; do
        parent="$parent/$c"
        [ -d "$parent" ] || { mkdir "$parent"; chown 1000:1000 "$parent"; }
    done
    unset IFS; set +f
    # Staged beside the snapshots, so shared/ never holds a half-copied path.
    cp -a "$src" "$stage"
    chown -R 1000:1000 "$stage"
    rm -rf "shared/$p"
    mv -T "$stage" "shared/$p"
    echo "Restored shared/$p from $snap."
    ;;
*) usage ;;
esac
