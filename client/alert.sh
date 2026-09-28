#!/bin/sh
# Pushes one message to URL when a Mutagen session stays disconnected, halted,
# conflicted or with problems; again only when that changes. Run it from cron.
set -eu

url=${1:?usage: alert.sh URL}
state=${XDG_STATE_HOME:-$HOME/.local/state}/cubby-alert
# A missing daemon is the failure itself; autostarting one would hide it.
export MUTAGEN_DISABLE_AUTOSTART=1

problems() {
    if ! out=$(mutagen sync list --template '{{range .}}{{.Paused}} {{json .Status}} {{len .Conflicts}} {{len .Alpha.ScanProblems}} {{len .Alpha.TransitionProblems}} {{len .Beta.ScanProblems}} {{len .Beta.TransitionProblems}} {{or .Name .Identifier}}{{"\n"}}{{end}}' 2>&1); then
        echo "mutagen daemon unreachable"
        return
    fi
    printf '%s\n' "$out" | while read -r paused status conflicts a1 a2 b1 b2 name; do
        [ "$paused" = false ] || continue
        status=${status#\"}
        status=${status%\"}
        n=$((a1 + a2 + b1 + b2))
        case $status in
            disconnected|connecting-*|halted-*) ;;
            *) [ "$conflicts" = 0 ] && [ "$n" = 0 ] && continue ;;
        esac
        echo "$name: $status, $conflicts conflicts, $n problems"
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
curl -fsS -d "$(uname -n): $p" "$url"
mkdir -p "${state%/*}"
printf '%s\n' "$p" > "$state"
