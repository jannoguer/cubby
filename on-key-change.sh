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
