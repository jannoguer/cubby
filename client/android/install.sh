#!/data/data/com.termux/files/usr/bin/bash
# Cubby Android client installer; client/android/README.md has the one-line invocation.
# Piped through bash, stdin is the script itself, so prompts read from /dev/tty.
# The body runs as main, called on the last line: bash has read the whole script
# before anything runs, so a cut-off download runs nothing.
# Overrides: CUBBY_SERVER_IP, CUBBY_SERVER_PORT, CUBBY_HOST_FINGERPRINT, CUBBY_MUTAGEN_VERSION.
set -eu

die() {
    echo "ERROR: $1" >&2
    exit 1
}

main() {
    case "${PREFIX-}" in
    *com.termux*) ;;
    *) die "this script must run inside Termux." ;;
    esac

    if ! { : < /dev/tty; } 2>/dev/null; then
        die "no terminal available for prompts; run from an interactive Termux session."
    fi

    echo "[1/9] Installing base packages"
    # Full upgrade: on an old bootstrap the new curl needs OpenSSL symbols a plain upgrade holds back.
    apt update
    apt -y -o Dpkg::Options::=--force-confnew full-upgrade
    apt -y install openssh curl proot

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

    # One file per device: reusing another device's name replaces its key and locks it out.
    echo "[5/9] Register this public key on the server as data/clients/<device>.pub, then run: docker compose restart server"
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
        [ -n "$SERVER_IP" ] || die "server address is required."
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
    User cubby
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
        [ -n "$KEYLINE" ] || die "could not fetch the host key from $HOST port $PORT."
        FINGERPRINT=$(printf '%s\n' "$KEYLINE" | ssh-keygen -lf - | awk '{print $2}')
        if [ "$FINGERPRINT" != "$CUBBY_HOST_FINGERPRINT" ]; then
            die "server presented $FINGERPRINT, expected $CUBBY_HOST_FINGERPRINT."
        fi
        # Replace any earlier line for this host: ssh accepts a match on any line, so a retired key would stay trusted.
        [ -f ~/.ssh/known_hosts ] && ssh-keygen -q -R "${KEYLINE%% *}" -f ~/.ssh/known_hosts
        printf '%s\n' "$KEYLINE" >> ~/.ssh/known_hosts
        chmod 600 ~/.ssh/known_hosts
    fi
    # Interactive: ssh itself shows the fingerprint on first contact and asks on the
    # terminal; a known host connects silently.
    echo "On first contact, compare the fingerprint ssh shows with the 'Host key fingerprint' line in 'docker compose logs server'."
    ssh -n -T -o StrictHostKeyChecking=ask cubby true || die "could not log in; register the key as data/clients/<device>.pub and restart the server, then rerun."

    echo "[8/9] Shared storage"
    if [ ! -L ~/storage/shared ]; then
        termux-setup-storage
        echo "Accept the Android permission dialog."
        n=0
        until [ -L ~/storage/shared ]; do
            n=$((n + 1))
            [ "$n" -le 120 ] || die "storage permission not granted; run termux-setup-storage and rerun."
            sleep 1
        done
    fi
    mkdir -p ~/storage/shared/Cubby

    echo "[9/9] Daemon service and sync session"
    # runit keeps the daemon alive across Termux sessions and restarts it if it dies.
    pkg install -y termux-services
    SVC="$PREFIX/var/service/mutagen"
    mkdir -p "$SVC/log"
    # No exec: proot ignores TERM, so runit's stop would never reach the daemon.
    cat > "$SVC/run" <<'RUN'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
termux-chroot mutagen daemon run &
pid=$!
trap 'termux-chroot mutagen daemon stop; wait "$pid"; exit' TERM
wait "$pid"
RUN
    chmod +x "$SVC/run"
    ln -sf "$PREFIX/share/termux-services/svlogger" "$SVC/log/run"
    # runsvdir normally starts with the next shell; start it now for this one.
    . "$PREFIX/etc/profile.d/start-services.sh"
    # That starts runsvdir in the background, and sv (sv-enable runs sv up)
    # fails until runsvdir's scan picks the service up; probe until it has.
    n=0
    until sv status mutagen > /dev/null 2>&1; do
        n=$((n + 1))
        [ "$n" -le 30 ] || die "runit did not pick up the mutagen service; see sv status mutagen."
        sleep 1
    done
    sv-enable mutagen
    # A daemon from an earlier run still runs the old binary, which the client
    # rejects; an older run script left TERM to proot, so sv cannot stop it.
    # daemon stop skips the version check and fails only when no daemon is
    # listening yet, in which case the one starting is already the new binary.
    if termux-chroot mutagen daemon stop > /dev/null 2>&1; then
        # The daemon removes its socket on exit; the wait below then sees the new one.
        n=0
        while [ -S ~/.mutagen/daemon/daemon.sock ]; do
            n=$((n + 1))
            [ "$n" -le 30 ] || die "old mutagen daemon did not stop; see $PREFIX/var/log/sv/mutagen/."
            sleep 1
        done
    fi
    # A client command would autostart its own daemon inside this proot and hang.
    n=0
    until [ -S ~/.mutagen/daemon/daemon.sock ]; do
        n=$((n + 1))
        [ "$n" -le 30 ] || die "mutagen daemon did not start; see sv status mutagen and $PREFIX/var/log/sv/mutagen/."
        sleep 1
    done
    if termux-chroot mutagen sync list cubby > /dev/null 2>&1; then
        echo "Sync session cubby already exists."
    else
        termux-chroot mutagen sync create --name=cubby ~/storage/shared/Cubby cubby:/shared
    fi
    termux-chroot mutagen sync list

    echo "Done. Files sync between ~/storage/shared/Cubby and the server while Termux runs."
    echo "Daemon: sv status mutagen; log: $PREFIX/var/log/sv/mutagen/current."
    echo "For boot start and battery settings see https://github.com/jannoguer/cubby/tree/main/client/android."
}

main "$@"
