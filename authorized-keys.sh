#!/bin/sh
# AuthorizedKeysCommand: serves keys/*.pub at every login, so adding or revoking
# a key needs no restart. Runs as nobody, so the files must be world-readable.
# Each key is tagged with its file name through a forced command (cubby-session).
set -u

[ "${1-}" = "syncuser" ] || exit 0

for f in /pubkeys/*.pub; do
    [ -f "$f" ] || continue
    name=${f##*/}; name=${name%.pub}
    # The name lands unquoted inside command="..."; the entrypoint reports rejects.
    case "$name" in *[!A-Za-z0-9._-]*) continue ;; esac
    ssh-keygen -lf "$f" > /dev/null 2>&1 || continue
    tr -d '\r' < "$f" | awk -v n="$name" 'NF { print "command=\"/usr/local/bin/cubby-session " n "\" " $0 }'
done
exit 0
