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
# login. Same test as that command, as the same user (-s runs the program directly).
served=0
for f in /pubkeys/*.pub; do
    [ -e "$f" ] || continue
    name=${f##*/}; name=${name%.pub}
    case "$name" in *[!A-Za-z0-9._-]*)
        echo "WARNING: $f is not served: the name may only contain letters, digits, . _ and -." >&2
        continue ;;
    esac
    if fp=$(su -s /usr/bin/ssh-keygen nobody -- -lf "$f" 2>/dev/null); then
        [ "$served" -eq 0 ] && echo "Authorized keys:"
        served=$((served + 1))
        echo "  $name: $fp"
    else
        echo "WARNING: $f is not served: malformed, or not readable by nobody (chmod 644 on the host)." >&2
    fi
done
[ "$served" -gt 0 ] || echo "WARNING: no usable public keys in /pubkeys; add a world-readable .pub file to keys/, no restart needed." >&2

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

mkdir -p /run/cubby-sessions
chown syncuser:syncuser /run/cubby-sessions

# Seed the served-key list, then cut a client whose key is deleted, moved out
# or rewritten (see cubby-on-key-change).
/usr/local/bin/cubby-on-key-change
inotifyd /usr/local/bin/cubby-on-key-change /pubkeys:dmwy &

exec /usr/sbin/sshd -D -e
