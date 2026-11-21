#!/bin/sh
# Starts nginx over /shared behind CUBBY_WEB_PASSWORD; "entrypoint.sh check" is the healthcheck.
set -eu

if [ "${1-}" = check ]; then
    # Without a password the page itself answers; with one, the challenge does.
    [ -z "$CUBBY_WEB_PASSWORD" ] && want=200 || want=401
    wget -S -q -O /dev/null http://127.0.0.1:8080/ 2>&1 | grep -q " $want "
    exit
fi

# Unset refuses to start; set but empty is the explicit choice of no login.
if [ -z "${CUBBY_WEB_PASSWORD+set}" ]; then
    echo "ERROR: set CUBBY_WEB_PASSWORD in .env; an empty value means no login." >&2
    exit 1
fi

exec nginx -e stderr -c /web/nginx.conf -g 'daemon off;'
