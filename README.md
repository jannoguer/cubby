# Cubby

Self-hosted file sync. One Alpine container runs a key-only sshd, every computer runs [Mutagen](https://mutagen.io) (tested with v0.18.1) against it, phones copy over [SFTP](#sftp), any browser can read the files through an opt-in [web view](#web), and two more containers keep hardlinked snapshots where no client key can reach them.

[![CI](https://img.shields.io/github/actions/workflow/status/jannoguer/cubby/ci.yml?branch=main&label=CI)](https://github.com/jannoguer/cubby/actions/workflows/ci.yml?query=branch%3Amain)

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop and the desktop, and you stop thinking about it. I wanted that feeling without relying on Dropbox, or watching it add features nobody asked for every quarter.

1. [Server](#server)
2. [Client](#client)
3. [Alerts](#alerts)
4. [Clients: add, revoke](#clients-add-revoke)
5. [Backups](#backups)
6. [Maintenance](#maintenance)
7. [Private folders](#private-folders)
8. [SFTP](#sftp)
9. [Web](#web)

## Server

Needs Docker with Compose and TCP `2222` (or `CUBBY_PORT`) reachable by the clients. Set it up:

```bash
git clone https://github.com/jannoguer/cubby.git cubby && cd cubby
mkdir -p data/config data/shared data/clients data/private data/backups data/private-backups
sudo chown 1000:1000 data/backups
sudo chown 0:0 data/private-backups
docker compose up --build -d
docker compose logs server | grep 'Host key fingerprint'
```

Optional settings (bind address, port, snapshot interval and count): `cp .env.example .env` and uncomment what you need.

Back up `data/config/ssh_host_keys/` (root-owned): it is the host key. The rest of `data/config/` is Mutagen's working state.

## Client

Install Mutagen:

```bash
brew install mutagen-io/mutagen/mutagen  # macOS, Linux
scoop install main/mutagen               # Windows
```

Binaries without a package manager: [releases](https://github.com/mutagen-io/mutagen/releases/latest).

Start the daemon automatically:

<details><summary>Windows, macOS: at login</summary>

```bash
mutagen daemon register
```

If macOS says the daemon is running: `mutagen daemon stop`, wait a second, register again, then `mutagen daemon start`.

</details>

<details><summary>Linux: at boot</summary>

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/mutagen.service <<EOF
[Service]
ExecStart=$(command -v mutagen) daemon run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
mutagen daemon stop
systemctl --user enable --now mutagen.service
loginctl enable-linger "$USER"
```

</details><br/>

Make a key without a passphrase, since Mutagen runs unattended:

```bash
ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519_cubby"
```

Put `~/.ssh/id_ed25519_cubby.pub` on the server as `data/clients/<name>.pub` (your name, which also names your private folder, see [Private folders](#private-folders)), then restart the server, see [Clients: add, revoke](#clients-add-revoke).

Add to `~/.ssh/config`:

```ssh_config
Host cubby
    HostName <server-ip>
    Port 2222
    User cubby
    IdentityFile ~/.ssh/id_ed25519_cubby
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

`Port` is your `CUBBY_PORT` if you set one. The keepalives drop a dead connection, after a network change or sleep, within 45 seconds, so Mutagen reconnects instead of waiting on it.

Create the session, and on the first connect compare the fingerprint ssh shows with the server log:

```bash
mutagen sync create --name=shared <local-folder> cubby:/shared
```

Day to day:

```bash
mutagen sync list shared        # status
mutagen sync terminate shared   # remove the session, files stay
mutagen daemon stop             # any mutagen command starts it again
```

On Linux with the systemd unit, stop the daemon with `systemctl --user stop mutagen.service` instead: the unit restarts a stopped daemon.

Deletions propagate within seconds; the backups are the safety net. Conflicts are never resolved by discarding data: edit the side you want to keep.

## Alerts

Notify when Mutagen isn't running, or a session stays disconnected, halted, conflicted or unable to sync some files for over a minute:

<details open><summary>Windows</summary>

```powershell
New-Item -ItemType Directory -Force $HOME\.local\bin | Out-Null
Invoke-WebRequest https://raw.githubusercontent.com/jannoguer/cubby/main/client/alert.ps1 -OutFile $HOME\.local\bin\cubby-alert.ps1
$action = New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$HOME\.local\bin\cubby-alert.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask cubby-alert -Action $action -Trigger $trigger -Settings $settings -Force
```

</details>

<details><summary>Linux</summary>

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user
curl -fsSL -o ~/.local/bin/cubby-alert https://raw.githubusercontent.com/jannoguer/cubby/main/client/alert.sh && chmod +x ~/.local/bin/cubby-alert
cat > ~/.config/systemd/user/cubby-alert.service <<EOF
[Service]
ExecStart=$HOME/.local/bin/cubby-alert
EOF
cat > ~/.config/systemd/user/cubby-alert.timer <<EOF
[Timer]
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF
systemctl --user enable --now cubby-alert.timer
```

</details>

<details><summary>macOS</summary>

```bash
mkdir -p ~/.local/bin ~/Library/LaunchAgents
curl -fsSL -o ~/.local/bin/cubby-alert https://raw.githubusercontent.com/jannoguer/cubby/main/client/alert.sh && chmod +x ~/.local/bin/cubby-alert
cat > ~/Library/LaunchAgents/cubby-alert.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>cubby-alert</string>
    <key>ProgramArguments</key><array><string>$HOME/.local/bin/cubby-alert</string></array>
    <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/cubby-alert 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cubby-alert.plist
```

</details>

## Clients: add, revoke

Add: drop the device's `.pub` into `data/clients/`. Revoke: delete it. Then:

```bash
docker compose restart server  # other clients reconnect on their own
```

> [!WARNING]
> Deleting `<name>.pub` also deletes its [private folder](#private-folders) at that restart; its snapshots keep it until they are pruned. To block a key and keep the folder, replace or empty the file's contents instead.

## Backups

The backup container snapshots `data/shared/` into `data/backups/` at start and every `CUBBY_BACKUP_INTERVAL` in which something changed. Snapshots are hardlinked, so unchanged files cost only a directory entry; `data/backups/latest` points at the newest and the oldest beyond `CUBBY_BACKUP_KEEP` are removed. With the defaults, hourly and 168 kept, a deletion stays recoverable for at least a week, longer when nothing changes. A larger `CUBBY_BACKUP_KEEP` is cheap. Under 10% free on the disk, runs skip the snapshot and say so in the log; nothing is pruned to make room.

`backup` and `backup-private` show unhealthy after two missed intervals, a stalled prune or under 10% free disk space. Check on them:

```bash
docker compose ps
docker compose logs -f backup
ls data/backups/
```

> [!CAUTION]
> Never copy into `data/shared/` as root: a client can plant a symlink there.

Restore `<path>`, relative to the snapshot, by unpacking it into the container as the sync user; the copy syncs to every client:

```bash
sudo flock data/backups tar -C data/backups/<snapshot> -cf - <path> | docker compose exec -T -u 1000:1000 server tar -C /shared -xf -
```

`flock` (util-linux) locks `data/backups` while `tar` reads: the restore may make new snapshots, and their pruning waits until it ends, so even the oldest snapshot stays readable while restoring. If a backup run falls within the restore, its log says `pruning postponed` and the next run catches up. To keep a snapshot for good, rename it to anything but a timestamp: only timestamp names are pruned.

Offsite copy, pulled from another machine:

```bash
rsync -aHS <server>:<cubby-dir>/data/backups/ backups/
```

`data/private-backups/` is readable only by root.

## Maintenance

Update, also monthly for Alpine and OpenSSH security fixes:

```bash
git pull
docker compose build --pull --no-cache
docker compose up -d
```

A plain `--build` reuses the cached `apk add` layer and never gets them.

Smoke test of the images and alerts (needs Docker, ssh and ssh-keygen):

```bash
sh test/test.sh
```

Rotate the host key:

```bash
docker compose down
sudo rm -rf data/config/ssh_host_keys
docker compose up -d
docker compose logs server | grep 'Host key fingerprint'
```

Then on every client: `ssh-keygen -R '[<server-ip>]:2222'`, with your `CUBBY_PORT` if you set one, and `ssh cubby true` to accept the new key after comparing its fingerprint with the log. Mutagen cannot answer that prompt, so it stays disconnected until you do.

## Private folders

Each `data/clients/<name>.pub` also gets `/private/<name>`, readable only by the keys in that file.

> [!TIP]
> **To share a private folder, put several keys in one `.pub`, one key per line.** For example:
>
> ```text
> data/clients/ana.pub      # ana's key
> data/clients/parents.pub  # ana's and ben's keys
> data/clients/family.pub   # ana's, ben's and eva's keys
> ```
>
> - ana sees `/shared`, `/private/ana`, `/private/parents` and `/private/family`
> - ben sees `/shared`, `/private/parents` and `/private/family`
> - eva sees `/shared` and `/private/family`

Naming rules: `a-z`, `0-9`, `_`, `-`, up to 32, not starting with `-`, not a system account such as `cubby`, `root` or `guest`. If a name breaks them, the server log says why it skipped the folder.

Log in as the folder's name to sync it:

```bash
mutagen sync create --name=family <family-folder> family@cubby:/private/family
```

> [!WARNING]
> Keep the local folder apart from the `shared` session's folder, not inside or around it: Mutagen merges them and copies private files into `/shared`.

`backup-private` snapshots the folders into `data/private-backups/`. To rename, `mv` both the `.pub` and `data/private/<name>` before restarting.

Each folder's uid:

```bash
(cd data/private && stat -c '%u  %n' -- *)
# 2000  victus-laptop-1
# 2001  msi-work-laptop-1
# ...
```

> [!CAUTION]
> Never restore a private folder as root: a client can plant a symlink there.

Restore as that uid, under the lock on `data/private-backups`, as in [Backups](#backups):

```bash
sudo flock data/private-backups tar -C data/private-backups/<snapshot> -cf - <name>/<path> | docker compose exec -T -u <uid>:1000 server tar -C /private -xf -
```

## SFTP

Copy single files or folders without a sync session. A push overwrites the server's file and Mutagen spreads it to every device; overwritten or deleted files come back only from [backups](#backups). The server has no rsync, only OpenSSH.

On a computer, use the key and `cubby` alias from [Client](#client):

```bash
scp cubby:/shared/<path> .                 # pull
scp -r <folder> cubby:/shared/<path>/      # push
sftp cubby                                 # interactive; cd /shared
scp <file> <name>@cubby:/private/<name>/   # private folder, logged in as its name
```

Android and iOS: any SFTP app with key login, server `<server-ip>`, port `2222` (or `CUBBY_PORT`). Shared folder: user `cubby`, path `/shared`. Private folder: user `<name>`, path `/private/<name>`. On first connect, compare the fingerprint the app shows with the server log.

Without `ssh-keygen`, make an Ed25519 key pair in the browser at [sshkeygen.dev](https://sshkeygen.dev), or [maxotto-agent.github.io/sshkeygen](https://maxotto-agent.github.io/sshkeygen/) if it is down. Import the private key into the app and register the `.pub` as in [Clients: add, revoke](#clients-add-revoke).

## Web

Read `/shared` from any browser, no key or install: a plain read-only "Index of /" with a `download` link per file (symlinks and names that are not valid UTF-8 are not listed, dotfiles only after **Show hidden files**), behind a password. Off by default. The password reads everything in `/shared`, dotfiles included; keep secrets in a [private folder](#private-folders), which the web view never sees.

Uncomment `COMPOSE_PROFILES=web` and `CUBBY_WEB_PASSWORD` in `.env`, then `docker compose up --build -d`. Log in with the browser's sign-in box: any username, that password. An empty `CUBBY_WEB_PASSWORD=` means no login; left unset, the web container refuses to start. Requests are capped at 10 per second per IP.

Nginx serves plain HTTP on `127.0.0.1:8080` (`CUBBY_WEB_BIND_ADDR`, `CUBBY_WEB_PORT`); put one HTTPS proxy or tunnel in front. It must pass `Authorization` and set `X-Forwarded-For`, and Cubby trusts only the last entry, so a second proxy in a row is not supported. Without the header all visitors share one IP, and one rate cap.
