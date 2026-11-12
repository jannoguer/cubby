#!/bin/sh
# Smoke test: builds both images and checks login, private folders, snapshots, pruning,
# restores, folder removal and the healthcheck. Needs docker, ssh and ssh-keygen. Run: sh test/test.sh
set -eu
cd "$(dirname "$0")/.."

# Git Bash would rewrite the container paths passed to docker.
export MSYS_NO_PATHCONV=1
export CUBBY_BIND_ADDR=127.0.0.1 CUBBY_PORT=22922 CUBBY_BACKUP_INTERVAL=2 CUBBY_BACKUP_KEEP=2

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
b=$(grep -o "'{{range .}}.*{{end}}'" client/windows/alert.ps1)
[ "$a" = "$b" ] || fail "alert.sh and alert.ps1 use different templates"

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
