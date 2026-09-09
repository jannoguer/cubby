#!/bin/sh
# AuthorizedKeysCommand: serves keys/*.pub at every login, so adding or revoking
# a key needs no restart. Runs as nobody, so the files must be world-readable.
# Each key is tagged with its file name through a forced command (cubby-session).
set -u

[ "${1-}" = "syncuser" ] || exit 0

for f in /pubkeys/*.pub; do
    [ -f "$f" ] || continue
    name=${f##*/}; name=${name%.pub}
    # Unquoted inside command="..." and a directory name under /run; the entrypoint reports rejects.
    case "$name" in ''|.|..|*[!A-Za-z0-9._-]*) continue ;; esac
    tr -d '\r' < "$f" | while IFS= read -r key || [ -n "$key" ]; do
        [ -n "$key" ] || continue
        line="command=\"/usr/local/bin/cubby-session $name\" $key"
        # Checked as served: a .pub that carries its own options would pass on
        # its own but sshd rejects the combined line.
        printf '%s\n' "$line" | ssh-keygen -lf - > /dev/null 2>&1 && printf '%s\n' "$line"
    done
done
exit 0
