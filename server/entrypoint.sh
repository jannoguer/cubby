#!/bin/sh
set -eu

KEYDIR=/config/ssh_host_keys
AUTH=/run/cubby/authorized_keys

mkdir -p "$KEYDIR"
[ -f "$KEYDIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEYDIR/ssh_host_ed25519_key"
chmod 600 "$KEYDIR/ssh_host_ed25519_key"
echo "Host key fingerprint: $(ssh-keygen -lf "$KEYDIR/ssh_host_ed25519_key.pub")"

# Built once per start from data/clients/*.pub: add or remove a file, then restart.
mkdir -p /run/cubby
: > "$AUTH"
count=0
for f in /clients/*.pub; do
    [ -f "$f" ] || continue
    if fp=$(ssh-keygen -lf "$f" 2>/dev/null); then
        { tr -d '\r' < "$f"; echo; } >> "$AUTH"
        echo "Authorized key ${f##*/}: $fp"
        count=$((count + 1))
    else
        echo "WARNING: $f is not a public key; skipped." >&2
    fi
done
chmod 644 "$AUTH"
[ "$count" -gt 0 ] || echo "WARNING: no public keys in data/clients/; nobody can log in." >&2

# The /config mount shadows the home adduser created in the image.
mkdir -p /config/home /shared
chmod 755 /config
chown cubby:cubby /config/home /shared
# Files placed into shared/ from the host. -h: never follow a symlink out of the tree.
find /shared ! -user 1000 -exec chown -h cubby:cubby {} +

# Fail once with the reason instead of restart-looping.
if ! /usr/sbin/sshd -t; then
    echo "ERROR: sshd configuration is invalid (see above)." >&2
    exit 1
fi
exec /usr/sbin/sshd -D -e
