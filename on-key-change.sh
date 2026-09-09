#!/bin/sh
# inotifyd hook for /pubkeys. sshd checks keys only at login, so a revoked
# client would stay connected: when a served key disappears or changes, end
# every syncuser process. The clients that still hold a key reconnect.
set -u

STATE=/run/cubby-served-keys

# One "name fingerprint" line per served key, from the same command sshd runs.
su -s /bin/sh nobody -c '/usr/local/bin/cubby-authorized-keys syncuser' \
    | while IFS= read -r line; do
        name=$(printf '%s\n' "$line" | sed -n 's/^command="[^ ]* \([^"]*\)".*/\1/p')
        fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        [ -n "$name" ] && [ -n "$fp" ] && echo "$name $fp"
    done | sort -u > "$STATE.new"

revoked=""
if [ -f "$STATE" ]; then
    if [ -s "$STATE.new" ]; then
        revoked=$(grep -vxF -f "$STATE.new" "$STATE" | awk '{print $1}' | sort -u | tr '\n' ' ')
    else
        revoked=$(awk '{print $1}' "$STATE" | sort -u | tr '\n' ' ')
    fi
fi
mv "$STATE.new" "$STATE"
[ -n "$revoked" ] || exit 0

# Any record of which session belongs to which key would be the client's own
# word, so all of uid 1000 goes. Passes repeat until nothing is left to kill.
ended=0
pass=0
while [ "$pass" -lt 5 ]; do
    pass=$((pass + 1))
    found=0
    for st in /proc/[0-9]*/status; do
        grep -qsE '^Uid:\s+1000\s' "$st" || continue
        grep -qsE '^State:\s+Z' "$st" && continue
        pid=${st#/proc/}; pid=${pid%/status}
        kill -KILL "$pid" 2>/dev/null && found=$((found + 1))
    done
    ended=$((ended + found))
    [ "$found" -gt 0 ] || break
done
echo "Key revoked: ${revoked% }; ended $ended process(es), other clients reconnect." >&2
