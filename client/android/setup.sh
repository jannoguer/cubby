#!/data/data/com.termux/files/usr/bin/bash
# cubby Android client installer. Run on a fresh Termux session:
#   apt update && apt -y -o Dpkg::Options::=--force-confnew full-upgrade && apt -y install curl && curl -fsSL https://raw.githubusercontent.com/jannoguer/cubby/main/client/android/setup.sh | bash
# The full-upgrade must precede installing curl: on an outdated bootstrap, new
# curl links against OpenSSL 3.5+ QUIC symbols the bootstrap's libssl lacks,
# and fixing that needs package replacements plain upgrade holds back.
# When piped through bash, stdin is the script itself, so prompts read from /dev/tty.
# Non-interactive overrides: CUBBY_SERVER_IP, CUBBY_SERVER_PORT.
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
VERSION=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/mutagen-io/mutagen/releases/latest)")
TMP=${TMPDIR:-$PREFIX/tmp}
curl -fL -o "$TMP/mutagen.tar.gz" "https://github.com/mutagen-io/mutagen/releases/download/${VERSION}/mutagen_linux_arm64_${VERSION}.tar.gz"

echo "[3/9] Installing mutagen ${VERSION}"
# The agent bundle must sit next to the binary: Mutagen looks for
# mutagen-agents.tar.gz in its own directory when connecting to the server.
tar -xzf "$TMP/mutagen.tar.gz" -C "$PREFIX/bin" mutagen mutagen-agents.tar.gz
rm "$TMP/mutagen.tar.gz"
termux-chroot mutagen version

echo "[4/9] SSH key"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# No passphrase: the daemon reconnects in the background with no TTY or
# agent, so it cannot decrypt a protected key.
if [ -f ~/.ssh/cubby ]; then
    echo "Key ~/.ssh/cubby already exists, keeping it."
else
    ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/cubby
fi

echo "[5/9] Register this public key on the server (e.g. keys/phone.pub), then run 'docker compose restart' there:"
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

echo "[7/9] Accepting the server host key"
ssh -o StrictHostKeyChecking=accept-new cubby true

echo "[8/9] Shared storage"
if [ ! -L ~/storage/shared ]; then
    termux-setup-storage
    echo "Accept the Android permission dialog."
    until [ -L ~/storage/shared ]; do sleep 1; done
fi
mkdir -p ~/storage/shared/Cubby

echo "[9/9] Sync session"
termux-chroot mutagen daemon run > /dev/null 2>&1 &
# Wait for the daemon socket instead of probing with a client command: a
# client probe would autostart its own daemon inside this proot and hang.
n=0
until [ -S ~/.mutagen/daemon/daemon.sock ]; do
    n=$((n + 1))
    [ "$n" -le 15 ] || { echo "ERROR: mutagen daemon did not start." >&2; exit 1; }
    sleep 1
done
if termux-chroot mutagen sync list cubby > /dev/null 2>&1; then
    echo "Sync session cubby already exists."
else
    termux-chroot mutagen sync create --name=cubby --ignore=/.cubby ~/storage/shared/Cubby cubby:/shared
fi
termux-chroot mutagen sync list

echo "Done. Files sync between ~/storage/shared/Cubby and the server."
echo "The daemon dies with Termux; restart it anytime with:"
echo "  termux-chroot mutagen daemon run > /dev/null 2>&1 &"
echo "For long syncs run termux-wake-lock and exempt Termux from battery optimization."
