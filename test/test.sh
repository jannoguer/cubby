#!/bin/sh
# Smoke test: checks client/alert.sh against stubs, then builds the images and checks login,
# private folders, snapshots, pruning, restores, folder removal, the healthchecks and the web view.
# Needs docker, ssh and ssh-keygen. Run: sh test/test.sh
set -eu
cd "$(dirname "$0")/.."

# Git Bash would rewrite the container paths passed to docker.
export MSYS_NO_PATHCONV=1
export CUBBY_BIND_ADDR=127.0.0.1 CUBBY_PORT=22922 CUBBY_BACKUP_INTERVAL=2 CUBBY_BACKUP_KEEP=2
export COMPOSE_PROFILES=web CUBBY_WEB_PORT=18080

tmp=$(mktemp -d)
dc() { docker compose -p cubbytest -f docker-compose.yml -f test/compose.yml "$@"; }
cleanup() {
    dc down -v --rmi local
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    dc logs --tail 40 >&2
    exit 1
}
# retry <seconds> <command...>: poll until the command succeeds.
retry() {
    n=$1
    shift
    until "$@" > /dev/null 2>&1; do
        n=$((n - 1))
        [ "$n" -gt 0 ] || return 1
        sleep 1
    done
}
# as <key> <user> <command...>: run a command on the server over ssh.
as() {
    key=$1 user=$2
    shift 2
    ssh -F "$tmp/config" -i "$tmp/$key" "$user@cubbytest" "$@"
}
# on <service> <script>: run a script inside a running container.
on() { docker exec "cubbytest-$1" sh -c "$2"; }
# seed <volume> <script>: run a script as root with the volume at /v, before the stack starts.
seed() { docker run --rm -i -u 0 -v "cubbytest_$1:/v" cubbytest-backup sh -c "$2"; }

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
if alert Darwin 1 "$down"; then
    fail "alert succeeded although the notification failed"
fi
rm "$h/notify-fails"
alert Darwin 1 "$down"
notified osascript "Mutagen isn't running."
echo "ok: alert"

for k in laptop phone guest; do
    ssh-keygen -q -t ed25519 -N "" -f "$tmp/$k"
done
cat > "$tmp/config" << EOF
Host cubbytest
    HostName 127.0.0.1
    Port $CUBBY_PORT
    IdentitiesOnly yes
    BatchMode yes
    UserKnownHostsFile $tmp/known_hosts
    StrictHostKeyChecking accept-new
EOF

dc up --no-start --build
for k in laptop phone guest; do
    seed clients "cat > /v/$k.pub" < "$tmp/$k.pub"
done
echo garbage | seed clients 'cat > /v/bad.pub'
seed backups 'chown 1000:1000 /v' < /dev/null
seed web 'chown 1000:1000 /v' < /dev/null
dc up -d

retry 30 as laptop cubby true || fail "no login as cubby"
logs=$(dc logs --no-log-prefix server 2>&1)
for want in 'Host key fingerprint: ' '/clients/bad.pub is not a public key; skipped.' \
    "no private folder for guest.pub: 'guest' is taken"; do
    printf '%s\n' "$logs" | grep -qF "$want" || fail "server log lacks: $want"
done
[ "$(as laptop cubby id -u)" = 1000 ] || fail "cubby is not uid 1000"
as laptop laptop 'echo secret > /private/laptop/n.txt' || fail "laptop cannot write its private folder"
[ "$(as laptop laptop stat -c %u /private/laptop)" = 2000 ] || fail "/private/laptop is not uid 2000"
if as phone laptop true 2> /dev/null; then
    fail "the phone key logged in as laptop"
fi
echo "ok: login and private folders"

# Web: requests run inside cubbytest-web with busybox wget; X-Forwarded-For stands in for the client IP.
# code <ip> <user:password> <path>: HTTP status. page <ip> <user:password> <path>: body.
code() {
    on web "wget -S -q -O /dev/null --header 'X-Forwarded-For: $1' --header 'Authorization: Basic $(printf '%s' "$2" | base64 | tr -d '\n')' 'http://127.0.0.1:8080/$3' 2>&1" |
        sed -n 's|^ *HTTP/[0-9.]* \([0-9]*\).*|\1|p' | tail -1
}
page() {
    on web "wget -q -O - --header 'X-Forwarded-For: $1' --header 'Authorization: Basic $(printf '%s' "$2" | base64 | tr -d '\n')' 'http://127.0.0.1:8080/$3'"
}
# method <verb> <ip> <user:password>: status line of a raw request, as busybox wget cannot send PUT.
method() {
    on web "printf '$1 /web.txt HTTP/1.0\\r\\nX-Forwarded-For: $2\\r\\nAuthorization: Basic $(printf '%s' "$3" | base64 | tr -d '\n')\\r\\nContent-Length: 1\\r\\n\\r\\nx' | nc -w 2 127.0.0.1 8080" | head -1
}
# headers <ip> <user:password> <path>: response headers of a raw GET, as busybox wget follows redirects.
headers() {
    on web "printf 'GET /$3 HTTP/1.0\\r\\nX-Forwarded-For: $1\\r\\nAuthorization: Basic $(printf '%s' "$2" | base64 | tr -d '\n')\\r\\n\\r\\n' | nc -w 2 127.0.0.1 8080" | sed '/^\r*$/q'
}
# totp <seconds from now>: the 6-digit code for that time.
totp() { on web "njs -n QuickJS -m -p /web -c \"import {totp} from './totp.js'; console.log(totp('$webseed', Math.floor(Date.now() / 1000) + $1, 6))\""; }

retry 30 on web "wget -S -q -O /dev/null http://127.0.0.1:8080/ 2>&1 | grep -q ' 401 '" || fail "web does not answer"
[ "$(on web 'stat -c %a /data/credentials')" = 600 ] || fail "web credentials are not mode 0600"
shown=$(on web '/entrypoint.sh show')
pass=$(printf '%s\n' "$shown" | sed -n 's/^password: //p')
webseed=$(printf '%s\n' "$shown" | sed -n 's/^seed: *//p' | tr -d ' ')
printf '%s\n' "$pass" | grep -qE '^[a-z]+(-[a-z]+){3}$' || fail "web password is not four words"
for w in $(printf '%s\n' "$pass" | tr - ' '); do
    on web "grep -qx $w /web/english.txt" || fail "web password word $w is not in the list"
done
printf '%s\n' "$webseed" | grep -qE '^[A-Z2-7]{32}$' || fail "web seed is not 32 base32 characters"
printf '%s\n' "$shown" | grep -qxF "otpauth://totp/Cubby?secret=$webseed&issuer=Cubby" || fail "web show lacks the otpauth link"
weblogs=$(dc logs --no-log-prefix web 2>&1)
printf '%s\n' "$weblogs" | grep -qF -e "$pass" -e "$webseed" && fail "web log holds the password or the seed"

vectors=$(on web "njs -n QuickJS -m -p /web -c \"import {base32, totp} from './totp.js'; const s = base32(Buffer.from('12345678901234567890')); console.log(s); for (const t of [59, 1111111109, 1111111111, 1234567890, 2000000000]) console.log(t + ' ' + totp(s, t, 8))\"")
# The seed line is RFC 4648 base32, as authenticator apps decode it; a round trip alone would hide a shared bug.
[ "$vectors" = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
59 94287082
1111111109 07081804
1111111111 14050471
1234567890 89005924
2000000000 69279037' ] || fail "base32 or RFC 6238 vectors differ: $vectors"

on web "printf 'GET / HTTP/1.0\\r\\n\\r\\n' | nc -w 2 127.0.0.1 8080" | grep -q '^WWW-Authenticate: Basic' || fail "web 401 lacks WWW-Authenticate"
as laptop cubby 'echo web-ok > /shared/web.txt; ln -s /etc/passwd /shared/link; ln -s / /shared/rootlink
    touch /shared/.hidden; mkdir /shared/sub; echo amp > "/shared/sub/a&b.txt"'
good=a:$pass$(totp 0)
[ "$(code 10.0.0.1 "$good" '')" = 200 ] || fail "web refused the password and current code"
page 10.0.0.1 "$good" '' | grep -q 'web.txt' || fail "web listing lacks web.txt"
[ "$(page 10.0.0.1 "$good" web.txt)" = web-ok ] || fail "web download differs"
[ "$(code 10.0.0.1 "$good" '')" = 200 ] || fail "web forgot the login"
[ "$(code 10.0.0.2 "$good" '')" = 401 ] || fail "web accepted the login from another IP"
[ "$(code 10.0.0.1 "b:${good#*:}" '')" = 401 ] || fail "web accepted a spent code under another username"
[ "$(code 10.0.0.1 "$good" link)" = 403 ] || fail "web served a symlink"
[ "$(code 10.0.0.1 "$good" rootlink/)" = 404 ] || fail "web listed a symlinked directory"
page 10.0.0.1 "$good" '' | grep -qE '>(link|rootlink/|\.hidden)<' && fail "web listing shows a symlink or a dotfile"
page 10.0.0.1 "$good" sub/ | grep -qF '<a href="a%26b.txt">a&amp;b.txt</a>' || fail "web listing does not escape names"
[ "$(page 10.0.0.1 "$good" 'sub/a%26b.txt?download=1')" = amp ] || fail "web download link differs"
headers 10.0.0.1 "$good" sub | grep -q '^Location: /sub/' || fail "web directory redirect is not relative"
headers 10.0.0.1 "$good" 'web.txt?download=1' | grep -q '^Content-Disposition: attachment' || fail "web ?download does not save"
headers 10.0.0.1 "$good" web.txt | grep -q '^Content-Disposition' && fail "web file opens as a download"
headers 10.0.0.1 "$good" web.txt | grep -q '^Content-Security-Policy: sandbox' || fail "web file is not sandboxed"
headers 10.0.0.1 "$good" '' | grep -q '^Content-Security-Policy: sandbox' && fail "web listing is sandboxed, which blocks downloads"
for verb in PUT DELETE; do
    case $(method $verb 10.0.0.1 "$good") in *' 403 '*) ;; *) fail "web did not refuse $verb" ;; esac
done
[ "$(page 10.0.0.1 "$good" web.txt)" = web-ok ] || fail "web file changed or vanished"

[ "$(code 10.0.0.3 "c:${pass}000000" '')" = 401 ] || fail "web first failure is not 401"
[ "$(code 10.0.0.3 "c:${pass}000001" '')" = 401 ] || fail "web second failure is not 401"
[ "$(code 10.0.0.3 "c:wrong-wrong-wrong-wrong$(totp 30)" '')" = 429 ] || fail "web third failure is not 429"
[ "$(code 10.0.0.3 "c:$pass$(totp 30)" '')" = 429 ] || fail "web let a blocked IP in"
[ "$(code 10.0.0.4 "c:$pass$(totp 30)" '')" = 200 ] || fail "web blocked another IP"
as laptop cubby 'rm -r /shared/web.txt /shared/link /shared/rootlink /shared/.hidden /shared/sub'

hc=$(docker inspect --format '{{index .Config.Healthcheck.Test 1}}' cubbytest-web)
on web "$hc" || fail "web healthcheck fails"
if COMPOSE_PROFILES= docker compose -f docker-compose.yml config --services | grep -qx web; then
    fail "web is part of the default stack"
fi
echo "ok: web"

as laptop cubby 'echo one > /shared/a.txt'
retry 20 on backup 'test -f /backups/latest/a.txt' || fail "no snapshot of a.txt"
skipped() { dc logs --no-log-prefix backup 2>&1 | grep -q 'no changes; snapshot skipped'; }
retry 20 skipped || fail "an unchanged interval was not skipped"
as laptop cubby 'touch /shared/.mutagen-temporary-x; echo two > /shared/b.txt'
retry 20 on backup 'test -f /backups/latest/b.txt' || fail "no snapshot of b.txt"
on backup 'test ! -e /backups/latest/.mutagen-temporary-x' || fail "a Mutagen temporary file was snapshotted"
old=$(on backup 'cd /backups && for d in 2*Z; do if [ -f "$d/a.txt" ] && [ ! -f "$d/b.txt" ]; then echo "$d"; fi; done')
on backup "test /backups/$old/a.txt -ef /backups/latest/a.txt" || fail "an unchanged file was not hardlinked"
echo "ok: snapshot, skip, exclude, hardlink"

# A renamed snapshot is never pruned; the one after it is, two changes later.
mid=$(on backup 'readlink /backups/latest')
on backup "mv /backups/$old /backups/keep"
for f in c d; do
    as laptop cubby "echo $f > /shared/$f.txt"
    retry 20 on backup "test -f /backups/latest/$f.txt" || fail "no snapshot of $f.txt"
done
retry 10 on backup "test ! -e /backups/$mid" || fail "$mid was not pruned"
on backup '[ "$(ls -d /backups/2*Z | wc -l)" -eq 2 ]' || fail "more than CUBBY_BACKUP_KEEP snapshots are kept"
on backup 'test -f /backups/keep/a.txt' || fail "the renamed snapshot was pruned"
echo "ok: prune and pin"

as laptop cubby 'rm /shared/a.txt'
on backup 'tar -C /backups/keep -cf - a.txt' | dc exec -T -u 1000:1000 server tar -C /shared -xf -
[ "$(as laptop cubby cat /shared/a.txt)" = one ] || fail "shared restore"

retry 20 on backup-private 'test -f /backups/latest/laptop/n.txt' || fail "no private snapshot of n.txt"
snap=$(on backup-private 'readlink /backups/latest')
as laptop laptop 'rm /private/laptop/n.txt'
retry 20 on backup-private "[ \"\$(readlink /backups/latest)\" != $snap ]" || fail "no private snapshot after the deletion"
on backup-private "mv /backups/$snap /backups/keep"
on backup-private 'tar -C /backups/keep -cf - laptop/n.txt' | dc exec -T -u 2000:1000 server tar -C /private -xf -
[ "$(as laptop laptop cat /private/laptop/n.txt)" = secret ] || fail "private restore"
[ "$(as laptop laptop stat -c %u /private/laptop/n.txt)" = 2000 ] || fail "private restore owner"
echo "ok: restores"

# A removed .pub takes its folder and home at the next start; an older snapshot still holds it.
as phone phone 'echo gone > /private/phone/p.txt' || fail "phone cannot write its private folder"
retry 20 on backup-private 'test -f /backups/latest/phone/p.txt' || fail "no private snapshot of p.txt"
on server 'test -d /config/homes/2001' || fail "phone has no home at /config/homes/2001"
seed clients 'rm /v/phone.pub' < /dev/null
dc restart server
retry 30 as laptop cubby true || fail "no login after removing phone.pub"
on server 'test ! -e /private/phone && test ! -e /config/homes/2001' || fail "phone's folder or home outlived its .pub"
[ "$(as laptop laptop cat /private/laptop/n.txt)" = secret ] || fail "removing phone.pub touched laptop's folder"
dc logs --no-log-prefix server 2>&1 | grep -qF 'Removed /private/phone (uid 2001)' || fail "server log lacks the removal"
retry 20 on backup-private 'test ! -e /backups/latest/phone' || fail "no private snapshot after the removal"
on backup-private 'ls /backups/2*Z/phone/p.txt > /dev/null' || fail "no older snapshot holds the removed folder"

# Without a valid key nothing is removed: an empty data/clients/ would take every folder.
seed clients 'rm /v/laptop.pub /v/guest.pub' < /dev/null
dc restart server
retry 30 on server "nc -w 2 127.0.0.1 22 </dev/null | grep -q '^SSH-'" || fail "sshd is not up without keys"
dc logs --no-log-prefix server 2>&1 | grep -qF 'no private folder is removed' || fail "server log lacks the no-keys warning"
on server 'test -d /private/laptop' || fail "a start without keys removed a private folder"
echo "ok: folder removal"

on backup '/entrypoint.sh check' || fail "healthcheck fails on a fresh snapshot"
dc stop backup
stale() { dc run --rm --no-deps -T backup /entrypoint.sh check 2>&1 | grep -q 'last snapshot is'; }
retry 15 stale || fail "healthcheck passes on a stale snapshot"
echo "ok: healthcheck"
echo "all passed"
