#!/data/data/com.termux/files/usr/bin/bash
# Cubby Android client installer; client/android/README.md has the one-line invocation.
# Piped through bash, stdin is the script itself, so prompts read from /dev/tty.
# The body runs as main, called on the last line: bash has read the whole script
# before anything runs, so a cut-off download runs nothing.
# Overrides: CUBBY_SERVER_IP, CUBBY_SERVER_PORT, CUBBY_HOST_FINGERPRINT, CUBBY_MUTAGEN_VERSION,
# CUBBY_POLL_INTERVAL, CUBBY_WAKE_LOCK.
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

    # Mutagen's default is 10s; shared storage is polled through proot, so every scan costs battery.
    POLL_INTERVAL=${CUBBY_POLL_INTERVAL:-30}
    case "$POLL_INTERVAL" in
    '' | *[!0-9]* | 0) die "CUBBY_POLL_INTERVAL must be a positive number of seconds." ;;
    esac
    WAKE_LOCK=${CUBBY_WAKE_LOCK:-1}
    case "$WAKE_LOCK" in
    0 | 1) ;;
    *) die "CUBBY_WAKE_LOCK must be 0 or 1." ;;
    esac

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
        if ! grep -qs "^ *ServerAliveInterval" ~/.ssh/config; then
            echo "Add 'ServerAliveInterval 15' and 'ServerAliveCountMax 3' to it to notice dropped connections sooner."
        fi
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
        # Keepalives: a network switch or Doze leaves a dead connection that
        # Mutagen would otherwise wait on instead of reconnecting.
        cat >> ~/.ssh/config <<EOF
Host cubby
    HostName ${SERVER_IP}
    Port ${PORT}
    User cubby
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
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
    pkg install -y termux-services termux-api
    SVC="$PREFIX/var/service/mutagen"
    mkdir -p "$SVC/log"
    # No exec: proot ignores TERM, so runit's stop would never reach the daemon.
    {
        printf '#!/data/data/com.termux/files/usr/bin/sh\nwake_lock=%s\n' "$WAKE_LOCK"
        cat <<'RUN'
exec 2>&1
# Without it Doze suspends Termux, and the sync with it.
if [ "$wake_lock" = 1 ]; then termux-wake-lock; fi
termux-chroot mutagen daemon run &
pid=$!
trap 'termux-chroot mutagen daemon stop; wait "$pid"; if [ "$wake_lock" = 1 ]; then termux-wake-unlock; fi; exit' TERM
wait "$pid"
RUN
    } > "$SVC/run"
    chmod +x "$SVC/run"
    ln -sf "$PREFIX/share/termux-services/svlogger" "$SVC/log/run"

    ALERT_SVC="$PREFIX/var/service/cubby-alert"
    mkdir -p "$ALERT_SVC/log"
    # Port of client/windows/alert.ps1; the notification clears on recovery.
    cat > "$ALERT_SVC/run" <<'ALERT'
#!/data/data/com.termux/files/usr/bin/sh
# Notifies when an unpaused Mutagen session stays disconnected, halted,
# conflicted or failing for over a minute; again only when that changes.
exec 2>&1
state=$HOME/.local/state/cubby/alert
# A missing daemon is the failure itself; autostarting one would hide it.
export MUTAGEN_DISABLE_AUTOSTART=1

problems() {
    # One string: termux-chroot joins its arguments and reruns them through
    # sh -c, so the quotes around the template must reach that inner sh.
    if ! out=$(termux-chroot "mutagen sync list --template '{{range .}}{{.Paused}} {{json .Status}} {{with .SessionState}}{{len .Conflicts}}{{else}}0{{end}} {{with .Alpha.EndpointState}}{{len .ScanProblems}} {{len .TransitionProblems}}{{else}}0 0{{end}} {{with .Beta.EndpointState}}{{len .ScanProblems}} {{len .TransitionProblems}}{{else}}0 0{{end}} {{with .SessionState}}{{.LastError}}{{end}}{{println}}{{end}}'" 2>&1); then
        case "$out" in
        *'(is the daemon running?)'*) echo "Mutagen isn't running." ;;
        *) echo "Can't check sync ($(printf '%s\n' "$out" | head -n 1 | sed 's/^Error: //'))." ;;
        esac
        return
    fi
    # The error comes last as it has spaces; any lines it spills onto are
    # skipped as they do not start with false.
    printf '%s\n' "$out" | while read -r paused status conflicts a1 a2 b1 b2 err; do
        [ "$paused" = false ] || continue
        case "$status" in
        '"connecting-alpha"') msg="Can't reach this device" ;;
        '"connecting-beta"') msg="Can't reach the server" ;;
        '"disconnected"') msg='Not connected' ;;
        '"halted-on-root-emptied"') msg='Stopped, the folder was emptied on one side' ;;
        '"halted-on-root-deletion"') msg='Stopped, the folder was deleted on one side' ;;
        '"halted-on-root-type-change"') msg='Stopped, the folder was replaced by a file on one side' ;;
        *) msg= ;;
        esac
        if [ -n "$msg" ]; then
            if [ -n "$err" ]; then msg="$msg ($err)"; fi
            msg="$msg."
        fi
        if [ "$conflicts" != 0 ]; then msg="${msg:+$msg }Conflicts to resolve: $conflicts."; fi
        n=$((a1 + a2 + b1 + b2))
        if [ "$n" != 0 ]; then msg="${msg:+$msg }Files that could not sync: $n."; fi
        if [ -n "$msg" ]; then echo "$msg"; fi
    done
}

while :; do
    p=$(problems)
    if [ -n "$p" ]; then
        # Rides out reconnects and brief scans.
        sleep 60
        p=$(problems)
    fi
    if [ -z "$p" ]; then
        if [ -f "$state" ]; then
            rm "$state"
            timeout 30 termux-notification-remove cubby-alert
        fi
    elif [ ! -f "$state" ] || [ "$(cat "$state")" != "$p" ]; then
        echo "$p"
        # termux-api hangs instead of failing when the Termux:API app is missing.
        if timeout 30 termux-notification --id cubby-alert --title cubby --content "$p"; then
            mkdir -p "${state%/*}"
            printf '%s\n' "$p" > "$state"
        else
            echo "Could not notify; install the Termux:API app and open it once."
        fi
    fi
    sleep 900
done
ALERT
    chmod +x "$ALERT_SVC/run"
    # runsvdir starts a new service at once; hold this one until the session exists.
    [ -e "$ALERT_SVC/supervise" ] || touch "$ALERT_SVC/down"
    ln -sf "$PREFIX/share/termux-services/svlogger" "$ALERT_SVC/log/run"

    # runsvdir normally starts with the next shell; start it now for this one.
    . "$PREFIX/etc/profile.d/start-services.sh"
    # That starts runsvdir in the background, and sv (sv-enable runs sv up)
    # fails until runsvdir's scan picks the services up; probe until it has.
    for s in mutagen cubby-alert; do
        n=0
        until sv status "$s" > /dev/null 2>&1; do
            n=$((n + 1))
            [ "$n" -le 30 ] || die "runit did not pick up the $s service; see sv status $s."
            sleep 1
        done
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
        echo "Sync session cubby already exists; terminate it and rerun to apply new session settings."
    else
        # Shared storage cannot hold symlinks, so one from another device would fail every scan.
        termux-chroot mutagen sync create --name=cubby \
            --watch-polling-interval-alpha="$POLL_INTERVAL" --symlink-mode=ignore \
            ~/storage/shared/Cubby cubby:/shared
    fi
    termux-chroot mutagen sync list
    # After the session exists, so its first check does not report the daemon restart.
    sv-enable cubby-alert
    # Rerun: the running loop still has the old run script.
    sv restart cubby-alert

    echo "Done. Files sync between ~/storage/shared/Cubby and the server while Termux runs."
    echo "Daemon: sv status mutagen; log: $PREFIX/var/log/sv/mutagen/current."
    echo "Alerts need the Termux:API app (F-Droid), opened once; log: $PREFIX/var/log/sv/cubby-alert/current."
    echo "For boot start and battery settings see https://github.com/jannoguer/cubby/tree/main/client/android."
}

main "$@"
