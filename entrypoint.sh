#!/bin/sh
set -eu

HOME_DIR=/config/home
KEYDIR=/config/ssh_host_keys

mkdir -p "$KEYDIR"
[ -f "$KEYDIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEYDIR/ssh_host_ed25519_key"
chmod 600 "$KEYDIR"/*_key
chmod 644 "$KEYDIR"/*_key.pub 2>/dev/null || true

mkdir -p "$HOME_DIR/.ssh"
: > "$HOME_DIR/.ssh/authorized_keys"
found=0
for f in /pubkeys/*.pub; do
    [ -e "$f" ] || continue
    cat "$f" >> "$HOME_DIR/.ssh/authorized_keys"
    found=1
done

if [ "$found" -eq 0 ]; then
    echo "ERROR: no public keys found in /pubkeys (need at least one .pub file)." >&2
    echo "Sleeping indefinitely to prevent a crash loop. Add a key and restart." >&2
    sleep infinity
fi

mkdir -p /shared

chmod 755 /config
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R syncuser:syncuser "$HOME_DIR"
[ "$(stat -c %u /shared)" = "1000" ] || chown -R syncuser:syncuser /shared

exec /usr/sbin/sshd -D -e
