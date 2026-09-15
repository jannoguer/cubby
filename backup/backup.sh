#!/bin/sh
# Hardlinked rsync snapshots of /shared into /backups every BACKUP_INTERVAL seconds;
# the newest BACKUP_KEEP are kept, /backups/latest points at the newest.
# "backup.sh check" is the healthcheck: fails when latest is older than two intervals.
set -eu

SRC=/shared
DST=/backups
INTERVAL=${BACKUP_INTERVAL:-3600}
KEEP=${BACKUP_KEEP:-168}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

case "$INTERVAL$KEEP" in
    *[!0-9]*|'') die "BACKUP_INTERVAL and BACKUP_KEEP must be whole numbers, got '$INTERVAL' and '$KEEP'." ;;
esac
[ "$INTERVAL" -ge 1 ] && [ "$KEEP" -ge 1 ] || die "BACKUP_INTERVAL and BACKUP_KEEP must be at least 1."

if [ "${1-}" = check ]; then
    [ -d "$DST/latest" ] || die "no snapshot yet"
    # The link's own mtime: rsync -a gives the snapshot directory the source tree's.
    age=$(( $(date +%s) - $(stat -c %Y "$DST/latest") ))
    [ "$age" -le $((INTERVAL * 2)) ] || die "last snapshot is ${age}s old"
    exit 0
fi

[ -w "$DST" ] || die "$DST is not writable by uid $(id -u); run 'chown 1000:1000 backups' on the host."

while :; do
    start=$(date +%s)
    ts=$(date -u +%Y-%m-%dT%H%M%SZ)
    incoming="$DST/.incoming"
    rm -rf "$incoming"
    if [ -e "$DST/$ts" ]; then
        echo "[$ts] snapshot already exists; skipping this run" >&2
    else
        # As uid 1000 rsync cannot chown. Du+rwx: a directory copied without owner access could never be pruned.
        set -- -a --no-owner --no-group --delete --chmod=Du+rwx
        [ -d "$DST/latest" ] && set -- "$@" --link-dest="$DST/latest"
        rc=0
        rsync "$@" "$SRC/" "$incoming/" || rc=$?
        case "$rc" in
            # 23: unreadable paths skipped (listed above); 24: files vanished mid-copy.
            0|23|24)
                mv "$incoming" "$DST/$ts"
                # Relative target so the link also resolves on the host.
                ln -sfn "$ts" "$DST/latest"
                echo "[$ts] snapshot written"
                ;;
            *)
                echo "[$ts] WARNING: rsync exited with code $rc; snapshot discarded" >&2
                rm -rf "$incoming"
                ;;
        esac
    fi

    # Lexical glob order is chronological for these names.
    n=0
    for d in "$DST"/????-??-??T??????Z; do
        [ -d "$d" ] && n=$((n + 1))
    done
    for d in "$DST"/????-??-??T??????Z; do
        [ "$n" -gt "$KEEP" ] || break
        [ -d "$d" ] || continue
        if rm -rf "$d"; then
            echo "[$ts] pruned ${d##*/}"
        else
            echo "[$ts] WARNING: could not prune ${d##*/}" >&2
        fi
        n=$((n - 1))
    done

    wait=$((INTERVAL - ($(date +%s) - start)))
    [ "$wait" -ge 1 ] || wait=1
    sleep "$wait"
done
