#!/bin/sh
set -eu

HOME_DIR=/config/home
KEYDIR=/config/ssh_host_keys
# Outside the sync user's home on purpose: syncuser gets a shell there and could
# point a symlink at a root-owned file to have the writes below land on it.
AK_DIR=/etc/ssh/authorized_keys

mkdir -p "$KEYDIR"
[ -f "$KEYDIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEYDIR/ssh_host_ed25519_key"
chmod 600 "$KEYDIR"/*_key
chmod 644 "$KEYDIR"/*_key.pub 2>/dev/null || true
echo "Host key fingerprint: $(ssh-keygen -lf "$KEYDIR/ssh_host_ed25519_key.pub")"

mkdir -p "$AK_DIR"
: > "$AK_DIR/syncuser"
found=0
for f in /pubkeys/*.pub; do
    [ -e "$f" ] || continue
    # sshd skips unparseable lines silently; fail loudly here instead.
    if ! fingerprints=$(ssh-keygen -lf "$f" 2>&1); then
        echo "WARNING: skipping $f: $fingerprints" >&2
        continue
    fi
    cat "$f" >> "$AK_DIR/syncuser"
    # A key file with no trailing newline would glue the next key onto its line
    # and invalidate both; sshd ignores the blank lines this adds.
    echo >> "$AK_DIR/syncuser"
    echo "Authorized $f:"
    echo "$fingerprints" | sed 's/^/  /'
    found=1
done

if [ "$found" -eq 0 ]; then
    echo "ERROR: no valid public keys found in /pubkeys (need at least one .pub file)." >&2
    echo "Sleeping indefinitely to prevent a crash loop. Add a key and restart." >&2
    sleep infinity
fi

mkdir -p /shared

chmod 755 /config
chmod 755 "$AK_DIR"
chmod 644 "$AK_DIR/syncuser"
# The /config mount shadows the home directory adduser created in the image.
# Not recursive: the Mutagen agent creates everything below as syncuser.
mkdir -p "$HOME_DIR"
chown syncuser:syncuser "$HOME_DIR"
# Checking only the root keeps a restart off a recursive chown of a large tree.
# Files added from the host under another owner need a manual chown to 1000:1000.
[ "$(stat -c %u /shared)" = "1000" ] || chown -R syncuser:syncuser /shared

# One clear message instead of a restart loop on an sshd that dies at every start.
if ! /usr/sbin/sshd -t; then
    echo "ERROR: sshd configuration is invalid (see above)." >&2
    exit 1
fi

exec /usr/sbin/sshd -D -e
