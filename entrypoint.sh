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
# login. Ask that command, as the same user, which keys it actually serves.
served=$(su -s /bin/sh nobody -c '/usr/local/bin/cubby-authorized-keys syncuser' \
    | sed -n 's/^command="[^ ]* \([^"]*\)".*/\1/p' | sort -u)
count=0
for f in /pubkeys/*.pub; do
    [ -e "$f" ] || continue
    name=${f##*/}; name=${name%.pub}
    case "$name" in ''|.|..|*[!A-Za-z0-9._-]*)
        echo "WARNING: $f is not served: the name may only contain letters, digits, . _ and -, and may not be empty, . or .." >&2
        continue ;;
    esac
    if printf '%s\n' "$served" | grep -qxF "$name"; then
        [ "$count" -eq 0 ] && echo "Authorized keys:"
        count=$((count + 1))
        echo "  $name: $(ssh-keygen -lf "$f")"
    else
        echo "WARNING: $f is not served: malformed, carries key options, or not readable by nobody (chmod 644 on the host)." >&2
    fi
done
[ "$count" -gt 0 ] || echo "WARNING: no usable public keys in /pubkeys; add a world-readable .pub file to keys/, no restart needed." >&2

mkdir -p /shared

chmod 755 /config
# The /config mount shadows the home adduser created in the image.
mkdir -p "$HOME_DIR"
chown syncuser:syncuser "$HOME_DIR"
# Root only: a recursive chown of a large tree on every restart is too slow.
[ "$(stat -c %u /shared)" = "1000" ] || chown -R syncuser:syncuser /shared

# A symlink planted by a client would send the root writes below elsewhere.
for d in "$CUBBY_DIR" "$CUBBY_DIR/client" "$CUBBY_DIR/backup"; do
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
        rm -f "$d"
    fi
done
mkdir -p "$CUBBY_DIR" "$CUBBY_DIR/backup"
# .cubby and client/ stay root-owned: clients run these scripts, so no client
# key may alter them or swap the directories for symlinks. backup/ is written
# by the backup container as uid 1000.
chown root:root "$CUBBY_DIR"
chmod 755 "$CUBBY_DIR"
chown syncuser:syncuser "$CUBBY_DIR/backup"
rm -f "$CUBBY_DIR"/backup_status.ok "$CUBBY_DIR"/backup_status.err # marker location before backup/
# rsync rather than rm+cp: unchanged files stay untouched and the tree never
# disappears, so clients have nothing spurious to sync. --delete stays inside client/.
rsync -a --delete --chown=root:root --chmod=D755,F644 /opt/cubby/client/ "$CUBBY_DIR/client/"

# Fail once with the reason instead of restart-looping.
if ! /usr/sbin/sshd -t; then
    echo "ERROR: sshd configuration is invalid (see above)." >&2
    exit 1
fi

mkdir -p /run/cubby-sessions
chown syncuser:syncuser /run/cubby-sessions

# Seed the served-key list, then cut a client whose key is deleted, moved out
# or rewritten (see cubby-on-key-change). After a watcher restart the hook runs first, for keys removed in the gap.
/usr/local/bin/cubby-on-key-change
(
    set +e
    while :; do
        inotifyd /usr/local/bin/cubby-on-key-change /pubkeys:dmwy
        echo "WARNING: inotifyd exited with code $?; restarting the key watcher." >&2
        sleep 1
        /usr/local/bin/cubby-on-key-change
    done
) &

exec /usr/sbin/sshd -D -e
