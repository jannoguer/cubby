#!/bin/sh
# Notifies when an unpaused Mutagen session stays disconnected, halted,
# conflicted or failing for over a minute; again only when that changes.
# Run from cron as the logged-on user; notify-send on Linux, osascript on macOS.
set -u

state=${XDG_STATE_HOME:-$HOME/.local/state}/cubby/alert
# cron's PATH has none of the usual install dirs.
PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH
# A missing daemon is the failure itself; autostarting one would hide it.
export MUTAGEN_DISABLE_AUTOSTART=1
# notify-send needs the session bus, which cron does not set.
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}

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

if command -v notify-send > /dev/null; then
    notify-send cubby "$p"
elif command -v osascript > /dev/null; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "cubby"' -e 'end run' "$p"
else
    echo "$p" >&2
fi
mkdir -p "${state%/*}"
printf '%s\n' "$p" > "$state"
