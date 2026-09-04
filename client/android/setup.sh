#!/data/data/com.termux/files/usr/bin/bash
# Cubby Android client installer; docs/ANDROID_SETUP.md has the one-line invocation.
# full-upgrade before installing curl: on an old bootstrap the new curl needs
# OpenSSL symbols a plain upgrade holds back.
# Piped through bash, stdin is the script itself, so prompts read from /dev/tty.
# Overrides: CUBBY_SERVER_IP, CUBBY_SERVER_PORT, CUBBY_HOST_FINGERPRINT, CUBBY_MUTAGEN_VERSION.
set -eu

case "${PREFIX-}" in
*com.termux*) ;;
*) echo "ERROR: this script must run inside Termux." >&2; exit 1 ;;
esac

if ! { : < /dev/tty; } 2>/dev/null; then
    echo "ERROR: no terminal available for prompts; run from an interactive Termux session." >&2
    exit 1
fi

echo "[1/9] Installing base packages"
pkg update -y && pkg upgrade -y -o Dpkg::Options::=--force-confnew
pkg install -y openssh curl proot

echo "[2/9] Downloading Mutagen"
VERSION=${CUBBY_MUTAGEN_VERSION:-$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/mutagen-io/mutagen/releases/latest)")}
BASE="https://github.com/mutagen-io/mutagen/releases/download/${VERSION}"
ARCHIVE="mutagen_linux_arm64_${VERSION}.tar.gz"
TMP=${TMPDIR:-$PREFIX/tmp}
curl -fL -o "$TMP/$ARCHIVE" "$BASE/$ARCHIVE"
curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"
# Same host as the archive: catches a bad download, not a compromised release.
(cd "$TMP" && grep " $ARCHIVE\$" SHA256SUMS | sha256sum -c -)

echo "[3/9] Installing mutagen ${VERSION}"
# Mutagen expects mutagen-agents.tar.gz next to its own binary.
tar -xzf "$TMP/$ARCHIVE" -C "$PREFIX/bin" mutagen mutagen-agents.tar.gz
rm "$TMP/$ARCHIVE" "$TMP/SHA256SUMS"
termux-chroot mutagen version

echo "[4/9] SSH key"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# No passphrase: the daemon reconnects with no TTY or agent to decrypt one.
if [ -f ~/.ssh/cubby ]; then
    echo "Key ~/.ssh/cubby already exists, keeping it."
else
    ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/cubby
fi

echo "[5/9] Register this public key on the server as keys/phone.pub (chmod 644); it works at once, no restart:"
echo
cat ~/.ssh/cubby.pub
echo
printf "Press Enter when done. "
read -r _ < /dev/tty

echo "[6/9] Host alias"
if grep -qs "^Host cubby$" ~/.ssh/config; then
    echo "Host cubby already present in ~/.ssh/config, keeping it."
else
    SERVER_IP=${CUBBY_SERVER_IP-}
    if [ -z "$SERVER_IP" ]; then
        printf "Server address: "
        read -r SERVER_IP < /dev/tty
    fi
    [ -n "$SERVER_IP" ] || { echo "ERROR: server address is required." >&2; exit 1; }
    PORT=${CUBBY_SERVER_PORT-}
    if [ -z "$PORT" ]; then
        printf "Server port [2222]: "
        read -r PORT < /dev/tty
        PORT=${PORT:-2222}
    fi
    cat >> ~/.ssh/config <<EOF
Host cubby
    HostName ${SERVER_IP}
    Port ${PORT}
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
fi

echo "[7/9] Server host key"
if [ -n "${CUBBY_HOST_FINGERPRINT-}" ]; then
    # Unattended: pin the key ourselves if it matches; ssh below then verifies against it.
    HOST=$(ssh -G cubby 2>/dev/null | awk '/^hostname /{print $2}')
    PORT=$(ssh -G cubby 2>/dev/null | awk '/^port /{print $2}')
    # Newer ssh-keyscan prints its banner comment on stdout.
    KEYLINE=$(ssh-keyscan -p "$PORT" -t ed25519 "$HOST" 2>/dev/null | grep -v '^#') || true
    [ -n "$KEYLINE" ] || { echo "ERROR: could not fetch the host key from $HOST port $PORT." >&2; exit 1; }
    FINGERPRINT=$(printf '%s\n' "$KEYLINE" | ssh-keygen -lf - | awk '{print $2}')
    if [ "$FINGERPRINT" != "$CUBBY_HOST_FINGERPRINT" ]; then
        echo "ERROR: server presented $FINGERPRINT, expected $CUBBY_HOST_FINGERPRINT." >&2
        exit 1
    fi
    printf '%s\n' "$KEYLINE" >> ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts
fi
# Interactive: ssh itself shows the fingerprint on first contact and asks on the
# terminal; a known host connects silently. -T: stdin is the piped script.
echo "Compare the fingerprint ssh shows with the 'Host key fingerprint' line in 'docker compose logs cubby'."
ssh -T -o StrictHostKeyChecking=ask cubby true

echo "[8/9] Shared storage"
if [ ! -L ~/storage/shared ]; then
    termux-setup-storage
    echo "Accept the Android permission dialog."
    until [ -L ~/storage/shared ]; do sleep 1; done
fi
mkdir -p ~/storage/shared/Cubby

echo "[9/9] Sync session"
termux-chroot mutagen daemon run > /dev/null 2>&1 &
# A client command would autostart its own daemon inside this proot and hang.
n=0
until [ -S ~/.mutagen/daemon/daemon.sock ]; do
    n=$((n + 1))
    [ "$n" -le 15 ] || { echo "ERROR: mutagen daemon did not start." >&2; exit 1; }
    sleep 1
done
if termux-chroot mutagen sync list Cubby > /dev/null 2>&1; then
    echo "Sync session Cubby already exists."
else
    # .cubby/local holds this device's health markers.
    termux-chroot mutagen sync create --name=Cubby --ignore=/.cubby/local ~/storage/shared/Cubby cubby:/shared
fi
termux-chroot mutagen sync list

echo "Done. Files sync between ~/storage/shared/Cubby and the server."
echo "The daemon dies with Termux; restart it anytime with:"
echo "  termux-chroot mutagen daemon run > /dev/null 2>&1 &"
echo "For long syncs run termux-wake-lock and exempt Termux from battery optimization."
