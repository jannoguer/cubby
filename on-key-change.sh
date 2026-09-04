#!/bin/sh
# inotifyd hook for /pubkeys. sshd checks keys only at login, so a revoked
# client would stay connected: end every session when a key that could log in
# disappears. The other clients reconnect within seconds; additions do nothing.
set -u

STATE=/run/cubby-served-keys

su -s /bin/sh nobody -c '/usr/local/bin/cubby-authorized-keys syncuser' \
    | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | sort -u > "$STATE.new"

if [ -f "$STATE" ]; then
    if [ -s "$STATE.new" ]; then
        revoked=$(grep -vxF -f "$STATE.new" "$STATE" || true)
    else
        revoked=$(cat "$STATE")
    fi
    if [ -n "$revoked" ]; then
        echo "Key revoked: $(echo "$revoked" | tr '\n' ' ')ending open sessions." >&2
        pkill -u syncuser || true
    fi
fi
mv "$STATE.new" "$STATE"
