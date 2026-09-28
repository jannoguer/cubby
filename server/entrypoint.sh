#!/bin/sh
set -eu

KEYDIR=/config/ssh_host_keys
KEY=$KEYDIR/ssh_host_ed25519_key
AUTH=/run/cubby/authorized_keys

# /etc/passwd and /etc/shadow link here, so this comes before any user lookup.
mkdir -p "$AUTH"
cp /etc/passwd.base /run/cubby/passwd
cp /etc/shadow.base /run/cubby/shadow
chmod 600 /run/cubby/shadow

# A uid-1000-owned /config would let the sync user swap the key directory; root takes it.
install -d -m 755 -o root -g root /config
install -d -m 700 -o root -g root "$KEYDIR"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY"
# Generated here as root, always; any other owner means the key was replaced.
if [ "$(stat -c %u "$KEY")" != 0 ]; then
    echo "ERROR: $KEY is not owned by root; the host key may have been replaced. Rotate it (README section 6)." >&2
    exit 1
fi
chmod 600 "$KEY"
# From the key sshd serves; the .pub sidecar is not kept in step with it.
echo "Host key fingerprint: $(ssh-keygen -y -f "$KEY" | ssh-keygen -lf -)"

install -d -m 755 -o root -g root /private /config/homes
# Folder owners are the only record of uids, so a revoked key's uid is never handed out again.
next=1999
for d in /private/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    u=$(stat -c %u "$d")
    [ "$u" -gt "$next" ] && next=$u
done

# Built once per start from data/clients/*.pub: add or remove a file, then restart.
# Every key logs in as cubby; the keys in <name>.pub also log in as <name>, owner of /private/<name>.
: > "$AUTH/cubby"
count=0
for f in /clients/*.pub; do
    [ -f "$f" ] || continue
    if ! fp=$(ssh-keygen -lf "$f" 2>/dev/null); then
        echo "WARNING: $f is not a public key; skipped." >&2
        continue
    fi
    keys=$(tr -d '\r' < "$f")
    printf '%s\n' "$keys" >> "$AUTH/cubby"
    echo "Authorized key ${f##*/}: $fp"
    count=$((count + 1))

    name=${f##*/}
    name=${name%.pub}
    if ! printf '%s' "$name" | grep -qx '[a-z0-9_][a-z0-9_-]\{0,31\}' || grep -q "^$name:" /run/cubby/passwd; then
        echo "WARNING: no private folder for ${f##*/}: '$name' is taken or not a user name (a-z 0-9 _ -, up to 32)." >&2
        continue
    fi
    d=/private/$name
    if [ -d "$d" ] && [ ! -L "$d" ]; then
        uid=$(stat -c %u "$d")
    elif [ -e "$d" ] || [ -L "$d" ]; then
        echo "WARNING: no private folder for ${f##*/}: $d is not a directory." >&2
        continue
    else
        next=$((next + 1))
        uid=$next
    fi
    # Below 2000 was made on the host (root, cubby); a uid already in passwd would open two folders to one key.
    if [ "$uid" -lt 2000 ] || grep -q ":x:$uid:" /run/cubby/passwd; then
        echo "WARNING: no private folder for ${f##*/}: $d is owned by uid $uid, which is reserved or in use; chown it to a free uid of 2000 or more." >&2
        continue
    fi
    home=/config/homes/$uid
    install -d -m 700 -o "$uid" -g 1000 "$d" "$home"
    echo "$name:x:$uid:1000::$home:/bin/sh" >> /run/cubby/passwd
    echo "$name:*:::::::" >> /run/cubby/shadow
    printf '%s\n' "$keys" > "$AUTH/$name"
    echo "Private folder /private/$name (uid $uid)"
done
chmod 644 "$AUTH"/*
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
for want in 'allowgroups cubby' 'authorizedkeysfile /run/cubby/authorized_keys/%u' \
    'authenticationmethods publickey' 'permitrootlogin no' 'passwordauthentication no'; do
    if ! printf '%s\n' "$effective" | grep -qx "$want"; then
        echo "ERROR: sshd is not applying '$want'; the drop-in in /etc/ssh/sshd_config.d is being ignored." >&2
        exit 1
    fi
done
exec /usr/sbin/sshd -D -e
