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
    # A key file with no trailing newline would glue the next key onto its line
    # and invalidate both; sshd ignores the blank lines this adds.
    echo >> "$HOME_DIR/.ssh/authorized_keys"
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
# Checking only the root keeps a restart off a recursive chown of a large tree.
# Files added from the host under another owner need a manual chown to 1000:1000.
[ "$(stat -c %u /shared)" = "1000" ] || chown -R syncuser:syncuser /shared

# Fail here with one clear message instead of restart-looping on an sshd that
# dies immediately after every start.
if ! /usr/sbin/sshd -t; then
    echo "ERROR: sshd configuration is invalid (see above)." >&2
    exit 1
fi

exec /usr/sbin/sshd -D -e
