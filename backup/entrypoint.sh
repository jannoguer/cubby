#!/bin/sh
# Hardlinked rsync snapshots of /shared into /backups every CUBBY_BACKUP_INTERVAL seconds,
# skipped when nothing changed; the newest CUBBY_BACKUP_KEEP are kept, /backups/latest points at the newest.
# "entrypoint.sh check" is the healthcheck: fails when latest is older than two intervals or under 1 GiB is free.
set -eu

SRC=/shared
DST=/backups
INTERVAL=${CUBBY_BACKUP_INTERVAL:-3600}
KEEP=${CUBBY_BACKUP_KEEP:-168}
MIN_FREE_KB=1048576

die() {
    echo "ERROR: $1" >&2
    exit 1
}

free_kb() {
    df -Pk "$DST" | awk 'NR == 2 { print $4 }'
}

report() {
    echo "[$ts] $1, $(( $(free_kb) / 1048576 )) GiB free"
}

case "$INTERVAL$KEEP" in
    *[!0-9]*|'') die "CUBBY_BACKUP_INTERVAL and CUBBY_BACKUP_KEEP must be whole numbers, got '$INTERVAL' and '$KEEP'." ;;
esac
[ "$INTERVAL" -ge 1 ] && [ "$KEEP" -ge 1 ] || die "CUBBY_BACKUP_INTERVAL and CUBBY_BACKUP_KEEP must be at least 1."

if [ "${1-}" = check ]; then
    kb=$(free_kb)
    [ "$kb" -ge "$MIN_FREE_KB" ] || die "only $((kb / 1024)) MiB free on $DST"
    [ -d "$DST/latest" ] || die "no snapshot yet"
    # The link's own mtime: rsync -a gives the snapshot directory the source tree's.
    age=$(( $(date +%s) - $(stat -c %Y "$DST/latest") ))
    [ "$age" -le $((INTERVAL * 2)) ] || die "last snapshot is ${age}s old"
    exit 0
fi

[ -w "$DST" ] || die "$DST is not writable by uid $(id -u); chown the host directory mounted there to $(id -u):$(id -g)."

while :; do
    start=$(date +%s)
    ts=$(date -u +%Y-%m-%dT%H%M%SZ)
    incoming="$DST/.incoming"
    rm -rf "$incoming"
    # As uid 1000 rsync cannot chown. Du+rwx: a directory copied without owner access could never be pruned.
    # -H -S: hardlinks and sparse files cost what they cost in the source. go-w,a-s: drop client-set bits.
    set -- -aHS --no-owner --no-group --delete --chmod=Du+rwx,go-w,a-s
    unchanged=0
    if [ -d "$DST/latest" ]; then
        # A path rsync cannot read is listed as a change every time, so a failing dry run just snapshots.
        changes=$(rsync -ni "$@" "$SRC/" "$DST/latest/") && [ -z "$changes" ] && unchanged=1
        set -- "$@" --link-dest="$DST/latest"
    fi
    if [ -e "$DST/$ts" ]; then
        echo "[$ts] snapshot already exists; skipping this run" >&2
    elif [ "$unchanged" = 1 ]; then
        touch -h "$DST/latest" # for the healthcheck
        report "no changes; snapshot skipped"
    else
        rc=0
        rsync "$@" "$SRC/" "$incoming/" || rc=$?
        case "$rc" in
            # 23: unreadable paths skipped (listed above); 24: files vanished mid-copy.
            0|23|24)
                mv "$incoming" "$DST/$ts"
                # Relative target so the link also resolves on the host.
                ln -sfn "$ts" "$DST/latest"
                report "snapshot written"
                ;;
            *)
                hint=
                [ "$rc" = 11 ] && hint=", disk full or an I/O error"
                echo "[$ts] WARNING: rsync exited with code $rc$hint; snapshot discarded" >&2
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
