#!/bin/sh
set -eu

KEYDIR=/config/ssh_host_keys
KEY=$KEYDIR/ssh_host_ed25519_key
AUTH=/run/cubby/authorized_keys

# A uid-1000-owned /config would let the sync user swap the key directory; root takes it.
chown root:root /config
chmod 755 /config
mkdir -p "$KEYDIR"
chown root:root "$KEYDIR"
chmod 700 "$KEYDIR"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY"
# Generated here as root, always; any other owner means the key was replaced.
if [ "$(stat -c %u "$KEY")" != 0 ]; then
    echo "ERROR: $KEY is not owned by root; the host key may have been replaced. Rotate it (README section 6)." >&2
    exit 1
fi
chmod 600 "$KEY"
# From the key sshd serves; the .pub sidecar is not kept in step with it.
echo "Host key fingerprint: $(ssh-keygen -y -f "$KEY" | ssh-keygen -lf -)"

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
chown cubby:cubby /config/home /shared
# Files placed into shared/ from the host. -h: never follow a symlink out of the tree.
find /shared ! -user 1000 -exec chown -h cubby:cubby {} +

# Fail once with the reason instead of restart-looping.
if ! /usr/sbin/sshd -t; then
    echo "ERROR: sshd configuration is invalid (see above)." >&2
    exit 1
fi
# The drop-in only applies through the Include in Alpine's stock sshd_config; check the effective values.
effective=$(/usr/sbin/sshd -T)
for want in 'allowusers cubby' 'authorizedkeysfile /run/cubby/authorized_keys' \
    'authenticationmethods publickey' 'permitrootlogin no' 'passwordauthentication no'; do
    if ! printf '%s\n' "$effective" | grep -qx "$want"; then
        echo "ERROR: sshd is not applying '$want'; the drop-in in /etc/ssh/sshd_config.d is being ignored." >&2
        exit 1
    fi
done
exec /usr/sbin/sshd -D -e
