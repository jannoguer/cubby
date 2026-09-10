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

die() {
    echo "ERROR: $1" >&2
    exit 1
}

[ -d shared ] && [ -d backups ] || die "run from the directory holding shared/ and backups/."

# A trailing slash or '.' makes cp, rm and stat follow a symlink at the leaf.
check_path() {
    case "$1" in
        ''|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*/) die "PATH must be relative to shared/, without '.' or '..' components or a trailing slash." ;;
    esac
}

# A symlink planted by a client anywhere on the path, leaf included, would send
# the root reads and writes below anywhere on the host. Fails on any symlinked
# component of PATH under BASE. This also refuses to restore a path that is
# itself a symlink in the snapshot or in shared/; recreate such a link by hand.
check_dirs() {
    base=$1
    set -f; IFS=/
    for c in $2; do
        base="$base/$c"
        [ -L "$base" ] && die "$base is a symlink; refusing to go through it."
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
    case "$snap" in */*|.|..) die "SNAPSHOT must be a snapshot name or 'latest'." ;; esac
    check_path "$p"
    case "$p" in .cubby|.cubby/*) die ".cubby is rebuilt by the server at start; restart the cubby container instead." ;; esac
    [ "$(id -u)" = 0 ] || die "run with sudo: the copy must be owned by uid 1000."
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
    check_dirs "backups/$snap" "$p"
    check_dirs shared "$p"
    src="backups/$snap/$p"
    [ -e "$src" ] || die "$src does not exist."
    if [ -e "shared/$p" ] && [ "$force" -eq 0 ]; then
        die "shared/$p exists; pass -f to replace it."
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
