#!/bin/sh
# Starts nginx over /shared; first start generates /data/credentials.
# "entrypoint.sh show" prints the password, the TOTP seed and the otpauth link.
set -eu

CREDS=/data/credentials

die() {
    echo "ERROR: $1" >&2
    exit 1
}

# The njs CLI has no ES module support in its default engine.
creds() {
    njs -n QuickJS -m -p /web /web/creds.js "$1"
}

if [ "${1-}" = show ]; then
    [ -f "$CREDS" ] || die "no credentials yet; start the container first."
    creds show
    exit 0
fi

[ -w /data ] || die "/data is not writable by uid $(id -u); chown the host directory mounted there to $(id -u):$(id -g)."

if [ ! -f "$CREDS" ]; then
    creds init
    echo "Credentials created; show them with: docker compose exec web /entrypoint.sh show"
fi

exec nginx -e stderr -c /web/nginx.conf -g 'daemon off;'
