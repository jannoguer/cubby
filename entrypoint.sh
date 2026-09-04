#!/bin/sh
set -eu

HOME_DIR=/config/home
KEYDIR=/config/ssh_host_keys
CUBBY_DIR=/shared/.cubby

mkdir -p "$KEYDIR"
[ -f "$KEYDIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEYDIR/ssh_host_ed25519_key"
chmod 600 "$KEYDIR"/*_key
chmod 644 "$KEYDIR"/*_key.pub 2>/dev/null || true
echo "Host key fingerprint: $(ssh-keygen -lf "$KEYDIR/ssh_host_ed25519_key.pub")"

# Report only: sshd reads /pubkeys live through cubby-authorized-keys at every
# login. Run the same command as the same user, so what prints is what logs in.
served=$(su -s /bin/sh nobody -c '/usr/local/bin/cubby-authorized-keys syncuser')
if [ -n "$served" ]; then
    echo "Authorized keys:"
    printf '%s\n' "$served" | ssh-keygen -lf - | sed 's/^/  /'
else
    echo "WARNING: no usable public keys in /pubkeys; add a world-readable .pub file to keys/, no restart needed." >&2
fi
# Same test as cubby-authorized-keys, as the same user; -s runs the program directly.
for f in /pubkeys/*.pub; do
    [ -e "$f" ] || continue
    su -s /usr/bin/ssh-keygen nobody -- -lf "$f" > /dev/null 2>&1 \
        || echo "WARNING: $f is not served: malformed, or not readable by nobody (chmod 644 on the host)." >&2
done

mkdir -p /shared

chmod 755 /config
# The /config mount shadows the home adduser created in the image.
mkdir -p "$HOME_DIR"
chown syncuser:syncuser "$HOME_DIR"
# Root only: a recursive chown of a large tree on every restart is too slow.
[ "$(stat -c %u /shared)" = "1000" ] || chown -R syncuser:syncuser /shared

# A symlink planted by a client would send the root writes below elsewhere.
for d in "$CUBBY_DIR" "$CUBBY_DIR/client"; do
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
        rm -f "$d"
    fi
done
mkdir -p "$CUBBY_DIR"
# Not recursive: the markers inside belong to whoever wrote them.
chown syncuser:syncuser "$CUBBY_DIR"
# rsync rather than rm+cp: unchanged files stay untouched and the tree never
# disappears, so clients have nothing spurious to sync. --delete stays inside client/.
rsync -a --delete --chown=syncuser:syncuser /opt/cubby/client/ "$CUBBY_DIR/client/"

# Fail once with the reason instead of restart-looping.
if ! /usr/sbin/sshd -t; then
    echo "ERROR: sshd configuration is invalid (see above)." >&2
    exit 1
fi

# Seed the served-key list, then cut open sessions when a key is deleted,
# moved out or rewritten (see cubby-on-key-change).
/usr/local/bin/cubby-on-key-change
inotifyd /usr/local/bin/cubby-on-key-change /pubkeys:dmwy &

exec /usr/sbin/sshd -D -e
