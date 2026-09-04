#!/bin/sh
# Hardlinked rsync snapshots of /shared in /backups; /backups/latest is the newest.
# After every run a marker lands in /status (shared/.cubby) and syncs to the clients.
set -eu

SRC=/shared
DST=/backups
STATUS_DIR=/status
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

# Healthcheck. The link's own mtime: rsync -a copies the source tree's mtime
# onto the snapshot directory.
check_latest() {
    link="$DST/latest"
    if [ ! -L "$link" ]; then
        echo "no snapshot yet: $link does not exist" >&2
        return 1
    fi
    if [ ! -d "$link" ]; then
        echo "$link points to a missing snapshot" >&2
        return 1
    fi
    age=$(( $(date +%s) - $(stat -c %Y "$link") ))
    # One interval would flap on a slow rsync.
    max=$((INTERVAL * 2))
    if [ "$age" -gt "$max" ]; then
        echo "last snapshot is ${age}s old, limit ${max}s" >&2
        return 1
    fi
    echo "last snapshot is ${age}s old"
}

case "${1-}" in
    '') ;;
    check) if check_latest; then exit 0; else exit 1; fi ;;
    *) echo "usage: backup.sh [check]" >&2; exit 2 ;;
esac

# Lexical glob order is chronological for these names.
count_snapshots() {
    total=0
    for d in "$DST"/????-??-??T??????Z; do
        [ -d "$d" ] && total=$((total + 1))
    done
    echo "$total"
}

snapshot_rc=0
snapshot() {
    ts=$(date -u +%Y-%m-%dT%H%M%SZ)
    incoming="$DST/.incoming-$ts"

    # Staging left behind by an interrupted run.
    # A restart right after a run: mv would nest the new tree inside the old one.
    if [ -e "$DST/$ts" ]; then
        echo "[$ts] snapshot already exists; skipping this run" >&2
        return 0
    fi
    for d in "$DST"/.incoming-*; do
        [ -e "$d" ] && rm -rf "$d"
    done

    # As uid 1000 rsync cannot chown, and the source is already ours.
    # The backup marker is this script's own output.
    set -- -a --no-owner --no-group --delete --chmod=Du+rwx \
    # Du+rwx: a directory copied without owner access could never be pruned.
        --exclude=/.cubby/backup_status.ok --exclude=/.cubby/backup_status.err \
        --exclude=/.cubby/.backup_status.tmp
    if [ -d "$DST/latest" ]; then
        set -- "$@" --link-dest="$DST/latest"
    fi
    rc=0
    rsync "$@" "$SRC/" "$incoming/" || rc=$?
    # 24: files vanished mid-copy, expected on a live sync root.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        echo "[$ts] WARNING: rsync exited with code $rc; snapshot discarded" >&2
        rm -rf "$incoming"
        snapshot_rc=$rc
        return 1
    fi
    mv "$incoming" "$DST/$ts"
    # Relative target so the link also resolves on the host.
    ln -sfn "$ts" "$DST/latest"
    echo "[$ts] snapshot written"

    excess=$(( $(count_snapshots) - KEEP ))
    for d in "$DST"/????-??-??T??????Z; do
        [ "$excess" -gt 0 ] || break
        [ -d "$d" ] || continue
        # BusyBox rm -f fails silently on a directory it cannot enter.
        if rm -rf "$d"; then
            echo "[$ts] pruned ${d##*/}"
        else
            echo "[$ts] WARNING: could not prune ${d##*/}" >&2
        fi
        excess=$((excess - 1))
    done
}

# key=value like the client markers. The stale marker goes last, so exactly one
# exists after each run. Never fatal: the snapshot itself succeeded or failed already.
failures=0
write_status() {
    result=$1
    if [ "$result" = ok ]; then
        marker=backup_status.ok; stale=backup_status.err
    else
        marker=backup_status.err; stale=backup_status.ok
    fi
    latest=""
    [ -L "$DST/latest" ] && latest=$(readlink "$DST/latest")
    tmp="$STATUS_DIR/.backup_status.tmp"
    if ! printf '%s\n' \
        "updatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "lastSnapshot=$latest" \
        "lastResult=$result" \
        "snapshots=$(count_snapshots)" \
        "keep=$KEEP" \
        "interval=$INTERVAL" \
        "consecutiveFailures=$failures" > "$tmp" || ! mv -f "$tmp" "$STATUS_DIR/$marker"; then
        echo "WARNING: could not write $STATUS_DIR/$marker; shared/.cubby must be owned by uid 1000." >&2
        rm -f "$tmp"
        return 0
    fi
    rm -f "$STATUS_DIR/$stale"
}

while :; do
    if snapshot; then
        failures=0
        write_status ok
    else
        failures=$((failures + 1))
        write_status "rsync-$snapshot_rc"
    fi
    sleep "$INTERVAL"
done
