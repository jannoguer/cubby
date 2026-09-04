#!/bin/sh
# AuthorizedKeysCommand: serves keys/*.pub at every login, so adding or revoking
# a key needs no restart. Runs as nobody, so the files must be world-readable.
set -u

[ "${1-}" = "syncuser" ] || exit 0

for f in /pubkeys/*.pub; do
    [ -f "$f" ] || continue
    # sshd would skip an unparseable line silently; the entrypoint reports it at start.
    ssh-keygen -lf "$f" > /dev/null 2>&1 || continue
    tr -d '\r' < "$f"
    # A key without a trailing newline would merge with the next one.
    echo
done
exit 0
