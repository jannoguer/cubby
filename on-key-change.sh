#!/bin/sh
# inotifyd hook for /pubkeys. sshd checks keys only at login, so a revoked
# client would stay connected: end the sessions of every key that disappeared
# or changed, and only those. Additions do nothing.
set -u

STATE=/run/cubby-served-keys
SESSIONS=/run/cubby-sessions

# One "name fingerprint" line per served key, from the same command sshd runs.
su -s /bin/sh nobody -c '/usr/local/bin/cubby-authorized-keys syncuser' \
    | while IFS= read -r line; do
        name=$(printf '%s\n' "$line" | sed -n 's/^command="[^ ]* \([^"]*\)".*/\1/p')
        fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        [ -n "$name" ] && [ -n "$fp" ] && echo "$name $fp"
    done | sort -u > "$STATE.new"

# The sshd session process for one connection, owned by syncuser.
is_session() {
    grep -qsE '^Name:\s+sshd' "/proc/$1/status" && grep -qsE '^Uid:\s+1000\s' "/proc/$1/status"
}

# Closing the connection does not end the commands it started.
kill_tree() {
    children=$(pgrep -P "$1")
    kill "$1" 2>/dev/null
    for c in $children; do kill_tree "$c"; done
}

end_sessions() {
    ended=0
    for p in "$SESSIONS/$1"/*; do
        [ -e "$p" ] || continue
        pid=${p##*/}
        if is_session "$pid"; then kill_tree "$pid"; ended=$((ended + 1)); fi
        rm -f "$p"
    done
    rmdir "$SESSIONS/$1" 2>/dev/null
    echo "Key revoked: $1, $ended session(s) ended." >&2
}

registered() {
    for d in "$SESSIONS"/*/; do
        [ -e "$d$1" ] && return 0
    done
    return 1
}

# The records are written by the clients themselves, so a hostile one can drop
# its own or leave a daemon behind that outlives its connection: end every
# syncuser process that does not descend from a session of a surviving key.
kill_orphans() {
    ended=0
    for st in /proc/[0-9]*/status; do
        grep -qsE '^Uid:\s+1000\s' "$st" || continue
        pid=${st#/proc/}; pid=${pid%/status}
        p=$pid
        while [ -n "$p" ] && [ "$p" -gt 1 ] && ! registered "$p"; do
            p=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$p/status" 2>/dev/null)
        done
        if [ -z "$p" ] || [ "$p" -le 1 ]; then kill "$pid" 2>/dev/null && ended=$((ended + 1)); fi
    done
    [ "$ended" -eq 0 ] || echo "Ended $ended process(es) outside any surviving session." >&2
}

revoked=""
if [ -f "$STATE" ]; then
    if [ -s "$STATE.new" ]; then
        revoked=$(grep -vxF -f "$STATE.new" "$STATE" | awk '{print $1}' | sort -u)
    else
        revoked=$(awk '{print $1}' "$STATE" | sort -u)
    fi
    for name in $revoked; do
        end_sessions "$name"
    done
fi
mv "$STATE.new" "$STATE"

# Entries whose connection is already gone.
for p in "$SESSIONS"/*/*; do
    [ -e "$p" ] || continue
    is_session "${p##*/}" || rm -f "$p"
done

[ -z "$revoked" ] || kill_orphans
