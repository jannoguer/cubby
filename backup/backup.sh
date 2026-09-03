#!/bin/sh
# Hardlinked rsync snapshots of /shared in /backups; /backups/latest is the newest.
set -eu

SRC=/shared
DST=/backups
INTERVAL=${BACKUP_INTERVAL:-86400}
KEEP=${BACKUP_KEEP:-14}

case "$INTERVAL" in
    ''|*[!0-9]*) echo "ERROR: BACKUP_INTERVAL must be a whole number of seconds, got '$INTERVAL'." >&2; exit 1 ;;
esac
case "$KEEP" in
    ''|*[!0-9]*|0) echo "ERROR: BACKUP_KEEP must be a whole number of at least 1, got '$KEEP'." >&2; exit 1 ;;
esac
if [ ! -w "$DST" ]; then
    echo "ERROR: $DST is not writable by uid $(id -u); run 'chown 1000:1000 backups' on the host." >&2
    exit 1
fi

snapshot() {
    ts=$(date -u +%Y-%m-%dT%H%M%SZ)
    incoming="$DST/.incoming-$ts"

    # Staging left behind by an interrupted run.
    for d in "$DST"/.incoming-*; do
        [ -e "$d" ] && rm -rf "$d"
    done

    # As uid 1000 rsync cannot chown, and the source is already ours.
    set -- -a --no-owner --no-group --delete
    if [ -d "$DST/latest" ]; then
        set -- "$@" --link-dest="$DST/latest"
    fi
    rc=0
    rsync "$@" "$SRC/" "$incoming/" || rc=$?
    # 24: files vanished mid-copy, expected on a live sync root.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        echo "[$ts] WARNING: rsync exited with code $rc; snapshot discarded" >&2
        rm -rf "$incoming"
        return 1
    fi
    mv "$incoming" "$DST/$ts"
    # Relative target so the link also resolves on the host.
    ln -sfn "$ts" "$DST/latest"
    echo "[$ts] snapshot written"

    # Lexical glob order is chronological for these names.
    total=0
    for d in "$DST"/????-??-??T??????Z; do
        [ -d "$d" ] && total=$((total + 1))
    done
    excess=$((total - KEEP))
    for d in "$DST"/????-??-??T??????Z; do
        [ "$excess" -gt 0 ] || break
        [ -d "$d" ] || continue
        rm -rf "$d"
        echo "[$ts] pruned ${d##*/}"
        excess=$((excess - 1))
    done
}

while :; do
    snapshot || true
    sleep "$INTERVAL"
done
