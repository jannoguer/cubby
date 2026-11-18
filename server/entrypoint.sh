#!/bin/sh
set -eu

KEYDIR=/config/ssh_host_keys
KEY=$KEYDIR/ssh_host_ed25519_key
AUTH=/run/cubby/authorized_keys

die() {
    echo "ERROR: $1" >&2
    exit 1
}

# A planted symlink must never pass for a private folder.
real_dir() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

uid_taken() {
    grep -q ":x:$1:" /run/cubby/passwd
}

# /etc/passwd and /etc/shadow link here, so this comes before any user lookup.
mkdir -p "$AUTH"
cp /etc/passwd.base /run/cubby/passwd
cp /etc/shadow.base /run/cubby/shadow
chmod 600 /run/cubby/shadow

# A uid-1000-owned /config would let the sync user swap the key directory; root takes it.
install -d -m 755 -o root -g root /config
# Before that fix the sync user could plant links here, which root would follow below.
for p in "$KEYDIR" "$KEY"; do
    [ ! -L "$p" ] || die "$p is a symlink; the host key may have been replaced. Rotate it (README section 9)."
done
for p in /config/home /config/homes; do
    if [ -L "$p" ]; then
        rm "$p"
        echo "WARNING: removed the symlink $p." >&2
    fi
done
install -d -m 700 -o root -g root "$KEYDIR"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY"
# Generated here as root, always; any other owner means the key was replaced.
[ "$(stat -c %u "$KEY")" = 0 ] || die "$KEY is not owned by root; the host key may have been replaced. Rotate it (README section 9)."
chmod 600 "$KEY"
# From the key sshd serves; the .pub sidecar is not kept in step with it.
echo "Host key fingerprint: $(ssh-keygen -y -f "$KEY" | ssh-keygen -lf -)"

install -d -m 755 -o root -g root /private /config/homes
# Folder owners are the only record of uids; a removed folder's uid is free again, its home went with it.
next=1999
for d in /private/*; do
    real_dir "$d" || continue
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
    pub=${f##*/}
    echo "Authorized key $pub: $fp"
    count=$((count + 1))

    name=${pub%.pub}
    if ! printf '%s' "$name" | grep -qx '[a-z0-9_][a-z0-9_-]\{0,31\}' || grep -q "^$name:" /run/cubby/passwd; then
        echo "WARNING: no private folder for $pub: '$name' is taken or not a user name (a-z 0-9 _ -, up to 32)." >&2
        continue
    fi
    d=/private/$name
    if real_dir "$d"; then
        uid=$(stat -c %u "$d")
    elif [ -e "$d" ] || [ -L "$d" ]; then
        echo "WARNING: no private folder for $pub: $d is not a directory." >&2
        continue
    else
        next=$((next + 1))
        uid=$next
    fi
    # Below 2000 was made on the host (root, cubby); a uid already in passwd would open two folders to one key.
    if [ "$uid" -lt 2000 ] || uid_taken "$uid"; then
        echo "WARNING: no private folder for $pub: $d is owned by uid $uid, which is reserved or in use; chown it to a free uid of 2000 or more." >&2
        continue
    fi
    home=/config/homes/$uid
    # A home holds only what $name wrote; anything else was planted while /config was the sync user's.
    if [ -L "$home" ] || { [ -d "$home" ] && [ -n "$(find "$home" -mindepth 1 ! -user "$uid" | head -n 1)" ]; }; then
        rm -rf "$home"
        echo "WARNING: removed $home: it held files not owned by uid $uid." >&2
    fi
    install -d -m 700 -o "$uid" -g 1000 "$d" "$home"
    echo "$name:x:$uid:1000::$home:/bin/sh" >> /run/cubby/passwd
    echo "$name:*:::::::" >> /run/cubby/shadow
    printf '%s\n' "$keys" > "$AUTH/$name"
    echo "Private folder /private/$name (uid $uid)"
done
chmod 644 "$AUTH"/*
if [ "$count" -eq 0 ]; then
    # An empty or unmounted data/clients/ must not take every folder with it.
    echo "WARNING: no public keys in data/clients/; nobody can log in, and no private folder is removed." >&2
else
    # A folder whose .pub is gone goes with it and its home; the snapshots hold it until pruned.
    for d in /private/*; do
        real_dir "$d" || continue
        name=${d##*/}
        uid=$(stat -c %u "$d")
        # Only what a key made here: below 2000 or a live user's uid was put there on the host.
        [ ! -e "/clients/$name.pub" ] && [ "$uid" -ge 2000 ] && ! uid_taken "$uid" || continue
        if rm -rf "$d" "/config/homes/$uid"; then
            echo "Removed /private/$name (uid $uid): $name.pub is gone."
        else
            echo "WARNING: could not remove $d" >&2
        fi
    done
fi

# The /config mount shadows the home adduser created in the image.
mkdir -p /config/home /shared
chown -h cubby:cubby /config/home /shared
# Files placed into shared/ from the host. -h: never follow a symlink out of the tree.
find /shared ! -user 1000 -exec chown -h cubby:cubby {} +

# Name the reason; Docker restarts the container either way.
/usr/sbin/sshd -t || die "sshd configuration is invalid (see above)."
# The drop-in only applies through the Include in Alpine's stock sshd_config; check the effective values.
effective=$(/usr/sbin/sshd -T)
for want in 'allowgroups cubby' 'authorizedkeysfile /run/cubby/authorized_keys/%u' \
    'authenticationmethods publickey' 'permitrootlogin no' 'passwordauthentication no' 'persourcemaxstartups 10'; do
    printf '%s\n' "$effective" | grep -qx "$want" || die "sshd is not applying '$want'; the drop-in in /etc/ssh/sshd_config.d is being ignored."
done
exec /usr/sbin/sshd -D -e
