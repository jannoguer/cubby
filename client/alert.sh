#!/bin/sh
# Notifies when an unpaused Mutagen session stays disconnected, halted,
# conflicted or failing for over a minute; again only when that changes.
# Run every few minutes as the logged-on user: launchd on macOS, a systemd timer on Linux.
set -u

state=${XDG_STATE_HOME:-$HOME/.local/state}/cubby/alert
# launchd's and systemd's PATH have none of the usual install dirs.
PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH
# A missing daemon is the failure itself; autostarting one would hide it.
export MUTAGEN_DISABLE_AUTOSTART=1

problems() {
    if ! command -v mutagen > /dev/null; then
        echo "Can't find mutagen on PATH."
        return
    fi
    if ! out=$(mutagen sync list --template '{{range .}}{{.Paused}} {{json .Status}} {{with .SessionState}}{{len .Conflicts}}{{else}}0{{end}} {{with .Alpha.EndpointState}}{{len .ScanProblems}} {{len .TransitionProblems}}{{else}}0 0{{end}} {{with .Beta.EndpointState}}{{len .ScanProblems}} {{len .TransitionProblems}}{{else}}0 0{{end}} {{with .SessionState}}{{.LastError}}{{end}}{{println}}{{end}}' 2>&1); then
        err=$(printf '%s\n' "$out" | head -n 1 | sed 's/^Error: //')
        case "$err" in
            *'(is the daemon running?)') echo "Mutagen isn't running." ;;
            *) echo "Can't check sync ($err)." ;;
        esac
        return
    fi
    # The error comes last as it has spaces; lines it spills onto do not start with false.
    printf '%s\n' "$out" | while read -r paused status conflicts a1 a2 b1 b2 err; do
        [ "$paused" = false ] || continue
        status=${status#\"}
        status=${status%\"}
        msg=
        case "$status" in
            connecting-alpha) msg="Can't reach this device" ;;
            connecting-beta) msg="Can't reach the server" ;;
            disconnected) msg='Not connected' ;;
            halted-on-root-emptied) msg='Stopped, the folder was emptied on one side' ;;
            halted-on-root-deletion) msg='Stopped, the folder was deleted on one side' ;;
            halted-on-root-type-change) msg='Stopped, the folder was replaced by a file on one side' ;;
        esac
        if [ -n "$msg" ]; then
            [ -n "$err" ] && msg="$msg ($err)"
            msg="$msg."
        fi
        [ "$conflicts" != 0 ] && msg="${msg:+$msg }Conflicts to resolve: $conflicts."
        n=$((a1 + a2 + b1 + b2))
        [ "$n" -gt 0 ] && msg="${msg:+$msg }Files that could not sync: $n."
        [ -n "$msg" ] && echo "$msg"
    done
}

p=$(problems)
if [ -n "$p" ]; then
    # Rides out reconnects and brief scans.
    sleep 60
    p=$(problems)
fi
if [ -z "$p" ]; then
    rm -f "$state"
    exit 0
fi
[ -f "$state" ] && [ "$(cat "$state")" = "$p" ] && exit 0

# busctl ships with systemd, unlike notify-send. A failed notification, such as one
# before the desktop is up, records nothing and is retried on the next run.
case $(uname) in
    Darwin) osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "cubby"' -e 'end run' "$p" ;;
    *) busctl --user call -- org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications Notify 'susssasa{sv}i' cubby 0 '' cubby "$p" 0 0 -1 > /dev/null ;;
esac || exit 1
mkdir -p "${state%/*}"
printf '%s\n' "$p" > "$state"
