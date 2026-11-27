#!/bin/sh
# Checks client/alert.sh: stubbed Mutagen cases, and with "mutagen" real sessions on the installed Mutagen.
# Run: sh test/client.sh [mutagen]
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
daemon=
cleanup() {
    # Only the isolated daemon started below; no other Mutagen on the machine is touched.
    if [ -n "$daemon" ]; then
        mutagen daemon stop
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

a=$(grep -o "'{{range .}}.*{{end}}'" client/alert.sh)
b=$(grep -o "'{{range .}}.*{{end}}'" client/alert.ps1)
[ "$a" = "$b" ] || fail "alert.sh and alert.ps1 use different templates"

# alert.sh puts $HOME/.local/bin first on PATH, so stubs there stand in for the real commands.
h=$tmp/home
mkdir -p "$h/.local/bin"
printf '#!/bin/sh\necho "$STUB_UNAME"\n' > "$h/.local/bin/uname"
printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_OUT"\nexit "$STUB_RC"\n' > "$h/.local/bin/mutagen"
printf '#!/bin/sh\n' > "$h/.local/bin/sleep"
for c in busctl osascript; do
    printf '#!/bin/sh\nprintf "%%s\\n" "${0##*/}" "$@" > "$HOME/notified"\n[ ! -e "$HOME/notify-fails" ]\n' > "$h/.local/bin/$c"
done
chmod +x "$h/.local/bin/"*
# alert <uname> <mutagen exit code> <mutagen output>: run alert.sh; $h/notified holds what it sent.
alert() {
    rm -f "$h/notified"
    HOME=$h XDG_STATE_HOME=$h/state STUB_UNAME=$1 STUB_RC=$2 STUB_OUT=$3 sh client/alert.sh
}
# notified <line...>: the last run sent a notification with these lines.
notified() {
    for l in "$@"; do
        grep -qxF -- "$l" "$h/notified" 2> /dev/null || fail "alert did not send: $l"
    done
}
down='Error: unable to connect to daemon: connection refused (is the daemon running?)'

alert Linux 0 'false "watching" 0 0 0 0 0
true "disconnected" 0 0 0 0 0 '
[ ! -e "$h/notified" ] || fail "alert on a healthy or paused session"
alert Linux 0 'false "connecting-beta" 0 0 0 0 0 dial tcp: i/o timeout
false "watching" 2 1 0 0 3 '
notified busctl Notify "Can't reach the server (dial tcp: i/o timeout)." 'Conflicts to resolve: 2. Files that could not sync: 4.'
alert Linux 0 'false "watching" 2 1 0 0 3 '
notified 'Conflicts to resolve: 2. Files that could not sync: 4.'
alert Linux 0 'false "watching" 2 1 0 0 3 '
[ ! -e "$h/notified" ] || fail "alert repeated an unchanged report"
alert Linux 0 ''
[ ! -e "$h/state/cubby/alert" ] || fail "alert kept its state after recovery"
touch "$h/notify-fails"
alert Darwin 1 "$down" && fail "alert succeeded although the notification failed"
rm "$h/notify-fails"
alert Darwin 1 "$down"
notified osascript "Mutagen isn't running."
alert Linux 0 'false "halted-on-root-deletion" 0 0 0 0 0 '
notified 'Stopped, the folder was deleted on one side.'
alert Linux 0 'false "watching" 1 0 0 0 0 '
notified 'Conflicts to resolve: 1.'
alert Linux 1 'Error: permission denied'
notified "Can't check sync (permission denied)."
# An error line spilling into one that starts with false: neither run as code nor an end to the report.
alert Linux 0 'false "connecting-beta" 0 0 0 0 0 dial tcp: reset
false "x" 0 HOME[$(touch${IFS}$HOME/pwned)] 0 0 0
false "disconnected" 0 0 0 0 0 '
notified "Can't reach the server (dial tcp: reset)." 'Not connected.'
[ ! -e "$h/pwned" ] || fail "alert ran a spilled error line as code"
echo "ok: alert, stubbed Mutagen"

[ "${1-}" = mutagen ] || exit 0

# The same alert.sh on what Mutagen really prints; only the notifier and the 60 s wait stay stubbed.
# A data directory of its own keeps these sessions apart from the machine's.
export MUTAGEN_DATA_DIRECTORY=$tmp/mutagen
rm "$h/.local/bin/mutagen"
mutagen daemon start
daemon=1
# session <name>: a synchronized session between two new local folders.
session() {
    mkdir "$tmp/$1-alpha" "$tmp/$1-beta"
    mutagen sync create --name="$1" "$tmp/$1-alpha" "$tmp/$1-beta"
    mutagen sync flush "$1"
}

session ok
alert "$(uname)" 0 ''
[ ! -e "$h/notified" ] || fail "alert on a healthy real session"

mkdir "$tmp/cf-alpha" "$tmp/cf-beta"
echo one > "$tmp/cf-alpha/x"
echo two > "$tmp/cf-beta/x"
mutagen sync create --name=cf "$tmp/cf-alpha" "$tmp/cf-beta"
mutagen sync flush cf
alert "$(uname)" 0 ''
notified 'Conflicts to resolve: 1.'
mutagen sync pause cf
alert "$(uname)" 0 ''
[ ! -e "$h/state/cubby/alert" ] || fail "alert kept reporting a paused real session"

# Root can read a file with no permissions, so there is nothing to fail on.
if [ "$(id -u)" != 0 ]; then
    mkdir "$tmp/ro-alpha" "$tmp/ro-beta"
    echo x > "$tmp/ro-alpha/locked"
    chmod 000 "$tmp/ro-alpha/locked"
    mutagen sync create --name=ro "$tmp/ro-alpha" "$tmp/ro-beta"
    mutagen sync flush ro
    alert "$(uname)" 0 ''
    notified 'Files that could not sync: 1.'
    mutagen sync pause ro
fi

session rd
rm -r "$tmp/rd-alpha"
n=0
until alert "$(uname)" 0 '' && [ -e "$h/notified" ]; do
    n=$((n + 1))
    [ "$n" -lt 30 ] || fail "a deleted session folder was never reported"
    sleep 1
done
grep -qF 'Stopped, the folder was deleted on one side' "$h/notified" || fail "alert did not send the root deletion: $(cat "$h/notified")"
mutagen sync pause rd

mutagen daemon stop
daemon=
alert "$(uname)" 0 ''
notified "Mutagen isn't running."
echo "ok: alert, real Mutagen"
