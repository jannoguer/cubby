#!/bin/sh
# Hardlinked rsync snapshots of /shared in /backups; /backups/latest is the newest.
# After every run a marker lands in /status (shared/.cubby/backup) and syncs to the clients.
set -eu

SRC=/shared
DST=/backups
STATUS_DIR=/status
INTERVAL=${BACKUP_INTERVAL:-3600}
KEEP_HOURLY=${BACKUP_KEEP_HOURLY:-24}
KEEP_DAILY=${BACKUP_KEEP_DAILY:-14}
KEEP_WEEKLY=${BACKUP_KEEP_WEEKLY:-8}
NTFY_URL=${NTFY_URL:-}
REMOTE=${BACKUP_REMOTE:-}
REMOTE_PORT=${BACKUP_REMOTE_PORT:-22}

case "$INTERVAL" in
    ''|*[!0-9]*) echo "ERROR: BACKUP_INTERVAL must be a whole number of seconds, got '$INTERVAL'." >&2; exit 1 ;;
esac
[ "$INTERVAL" -ge 1 ] || { echo "ERROR: BACKUP_INTERVAL must be at least 1 second, got '$INTERVAL'." >&2; exit 1; }
case "$KEEP_HOURLY" in
    ''|*[!0-9]*|0) echo "ERROR: BACKUP_KEEP_HOURLY must be a whole number of at least 1, got '$KEEP_HOURLY'." >&2; exit 1 ;;
esac
case "$KEEP_DAILY$KEEP_WEEKLY" in
    ''|*[!0-9]*) echo "ERROR: BACKUP_KEEP_DAILY and BACKUP_KEEP_WEEKLY must be whole numbers, got '$KEEP_DAILY' and '$KEEP_WEEKLY'." >&2; exit 1 ;;
esac
case "$REMOTE_PORT" in
    ''|*[!0-9]*) echo "ERROR: BACKUP_REMOTE_PORT must be a whole number, got '$REMOTE_PORT'." >&2; exit 1 ;;
esac
if [ -n "$REMOTE" ] && [ ! -r /offsite/id_ed25519 ]; then
    echo "ERROR: BACKUP_REMOTE is set but /offsite/id_ed25519 is missing or not readable by uid 1000." >&2
    exit 1
fi
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

# Survivors: the newest snapshot of each of the last KEEP_HOURLY hours, the first
# of each of the last KEEP_DAILY days and the first of each of the last KEEP_WEEKLY
# ISO weeks. Buckets are counted, not aged, so a stopped server loses no history.
prune() {
    for d in "$DST"/????-??-??T??????Z; do
        [ -d "$d" ] || continue
        s=${d##*/}
        echo "$s $(date -u -D %Y-%m-%d -d "${s%%T*}" +%G-%V)"
    done | awk -v H="$KEEP_HOURLY" -v D="$KEEP_DAILY" -v W="$KEEP_WEEKLY" '
        { name[NR] = $1; hour[NR] = substr($1, 1, 13); day[NR] = substr($1, 1, 10); week[NR] = $2 }
        END {
            for (i = NR; i >= 1; i--) if (!(hour[i] in hs)) { hs[hour[i]] = 1; if (++hn <= H) keep[i] = 1 }
            for (i = 1; i <= NR; i++) {
                if (!(day[i] in ds)) { ds[day[i]] = 1; dl[++dn] = i }
                if (!(week[i] in ws)) { ws[week[i]] = 1; wl[++wn] = i }
            }
            for (k = dn; k > dn - D && k >= 1; k--) keep[dl[k]] = 1
            for (k = wn; k > wn - W && k >= 1; k--) keep[wl[k]] = 1
            for (i = 1; i <= NR; i++) if (!(i in keep)) print name[i]
        }' | while IFS= read -r s; do
        # BusyBox rm -f fails silently on a directory it cannot enter.
        if rm -rf "$DST/${s:?}"; then
            echo "[$ts] pruned $s"
        else
            echo "[$ts] WARNING: could not prune $s" >&2
        fi
    done
}

snapshot_fail=""
snapshot_skipped=0
RSYNC_ERR=/tmp/rsync-errors
snapshot() {
    ts=$(date -u +%Y-%m-%dT%H%M%SZ)
    snapshot_skipped=0
    incoming="$DST/.incoming-$ts"
    # A restart right after a run: mv would nest the new tree inside the old one.
    if [ -e "$DST/$ts" ]; then
        echo "[$ts] snapshot already exists; skipping this run" >&2
        return 0
    fi

    # Staging left behind by an interrupted run.
    for d in "$DST"/.incoming-*; do
        [ -e "$d" ] && rm -rf "$d"
    done

    # As uid 1000 rsync cannot chown, and the source is already ours.
    # Du+rwx: a directory copied without owner access could never be pruned.
    # /.cubby/backup is this script's own output.
    set -- -a --no-owner --no-group --delete --chmod=Du+rwx --exclude=/.cubby/backup/
    if [ -d "$DST/latest" ]; then
        set -- "$@" --link-dest="$DST/latest"
    fi
    rc=0
    rsync "$@" "$SRC/" "$incoming/" 2> "$RSYNC_ERR" || rc=$?
    cat "$RSYNC_ERR" >&2
    case "$rc" in
        # 24: files vanished mid-copy, expected on a live sync root.
        0|24) ;;
        # 23: unreadable paths (listed above) were skipped; the rest is still worth keeping.
        23)
            snapshot_skipped=$(grep -c '^rsync: ' "$RSYNC_ERR")
            echo "[$ts] WARNING: $snapshot_skipped path(s) skipped; snapshot kept without them" >&2
            ;;
        *)
            echo "[$ts] WARNING: rsync exited with code $rc; snapshot discarded" >&2
            rm -rf "$incoming"
            snapshot_fail="rsync-$rc"
            return 1
            ;;
    esac
    if ! mv "$incoming" "$DST/$ts"; then
        echo "[$ts] WARNING: could not move the finished snapshot into place; snapshot discarded" >&2
        rm -rf "$incoming"
        snapshot_fail="mv"
        return 1
    fi
    # Relative target so the link also resolves on the host.
    ln -sfn "$ts" "$DST/latest"
    echo "[$ts] snapshot written"
    prune
}

# key=value like the client markers. The stale marker goes last, so exactly one
# exists after each run. Never fatal: the snapshot itself succeeded or failed already.
# A partial snapshot is still a snapshot: status.ok with lastResult=partial and skipped=N.
failures=0
write_status() {
    result=$1
    if [ "$result" = ok ] || [ "$result" = partial ]; then
        marker=status.ok; stale=status.err
    else
        marker=status.err; stale=status.ok
    fi
    latest=""
    [ -L "$DST/latest" ] && latest=$(readlink "$DST/latest")
    tmp="$STATUS_DIR/.status.tmp"
    if ! printf '%s\n' \
        "updatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "lastSnapshot=$latest" \
        "lastResult=$result" \
        "skipped=$snapshot_skipped" \
        "snapshots=$(count_snapshots)" \
        "keepHourly=$KEEP_HOURLY" \
        "keepDaily=$KEEP_DAILY" \
        "keepWeekly=$KEEP_WEEKLY" \
        "interval=$INTERVAL" \
        "ntfyUrl=$NTFY_URL" \
        "offsite=$offsite_result" \
        "consecutiveFailures=$failures" > "$tmp" || ! mv -f "$tmp" "$STATUS_DIR/$marker"; then
        echo "WARNING: could not write $STATUS_DIR/$marker; shared/.cubby/backup must be owned by uid 1000." >&2
        rm -f "$tmp"
        return 0
    fi
    rm -f "$STATUS_DIR/$stale"
}

# Push through ntfy when NTFY_URL is set; a failed push is logged and forgotten.
notify() {
    [ -n "$NTFY_URL" ] || return 0
    wget -q -T 10 -O /dev/null --post-data="$2" --header="Title: Cubby backup" --header="Priority: $1" "$NTFY_URL" \
        || echo "WARNING: could not notify $NTFY_URL" >&2
}

# The whole tree in one run so hardlinks survive; --delete mirrors pruning.
offsite_result=off
push_offsite() {
    [ -n "$REMOTE" ] || return 0
    rc=0
    rsync -aH --delete --exclude='/.incoming-*' --exclude='/.restore-*' \
        -e "ssh -p $REMOTE_PORT -i /offsite/id_ed25519 -o UserKnownHostsFile=/offsite/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=30" \
        "$DST/" "$REMOTE/" 2> "$RSYNC_ERR" || rc=$?
    sed 's/^/[offsite] /' "$RSYNC_ERR" >&2
    if [ "$rc" -eq 0 ]; then
        offsite_result=ok
        echo "[$ts] offsite copy done"
    else
        offsite_result="rsync-$rc"
        echo "[$ts] WARNING: offsite copy failed with rsync exit $rc" >&2
    fi
}

# Only on change; a fresh start counts as coming from ok, so an ongoing failure is reported once.
last=""
offsite_last=""
while :; do
    run_start=$(date +%s)
    if snapshot; then
        failures=0
        if [ "$snapshot_skipped" -eq 0 ]; then result=ok; else result=partial; fi
    else
        failures=$((failures + 1))
        result=$snapshot_fail
    fi
    push_offsite
    write_status "$result"
    if [ "$result" != "${last:-ok}" ]; then
        case "$result" in
            ok) notify default "Backups recovered: snapshot $(readlink "$DST/latest") written." ;;
            partial) notify high "Backup partial: $snapshot_skipped unreadable path(s) skipped; see the cubby-backup log." ;;
            *) notify high "Backup failed ($result), no snapshot written; see the cubby-backup log." ;;
        esac
    fi
    last=$result
    if [ "$offsite_result" != off ] && [ "$offsite_result" != "${offsite_last:-ok}" ]; then
        case "$offsite_result" in
            ok) notify default "Offsite copy recovered." ;;
            *) notify high "Offsite copy failed: rsync exit ${offsite_result#rsync-}; see the cubby-backup log." ;;
        esac
    fi
    offsite_last=$offsite_result
    wait=$((INTERVAL - ($(date +%s) - run_start)))
    [ "$wait" -ge 1 ] || wait=1
    sleep "$wait"
done
