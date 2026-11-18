# Cubby

Self-hosted file sync. One Alpine container runs a key-only sshd, every computer runs [Mutagen](https://mutagen.io) (tested with v0.18.1) against it, phones copy over [SFTP](#7-sftp), any browser can read the files through an opt-in [web view](#8-web), and two more containers keep hardlinked snapshots where no client key can reach them.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop and the desktop, and you stop thinking about it. I wanted that feeling without relying on Dropbox, or watching it add features nobody asked for every quarter.

1. [Server](#1-server)
2. [Client](#2-client)
3. [Daemon on boot and alerts](#3-daemon-on-boot-and-alerts)
4. [Backups](#4-backups)
5. [Clients: add, revoke](#5-clients-add-revoke)
6. [Private folders](#6-private-folders)
7. [SFTP](#7-sftp)
8. [Web](#8-web)
9. [Maintenance](#9-maintenance)
10. [Layout](#10-layout)

## 1. Server

Needs Docker with Compose and TCP `2222` (or `CUBBY_PORT`) reachable by the clients. Docker skips ufw.

```bash
git clone https://github.com/jannoguer/cubby.git cubby && cd cubby
mkdir -p data/config data/shared data/clients data/backups data/private-backups data/web
sudo chown 1000:1000 data/backups data/web
sudo chown 0:0 data/private-backups
docker compose up --build -d
docker compose logs server | grep 'Host key fingerprint'
```

Optional settings (bind address, port, snapshot interval and count): `cp .env.example .env` and uncomment what you need.

Back up `data/config/ssh_host_keys/` (root-owned): it is the host key. The rest of `data/config/` is Mutagen's working state.

## 2. Client

Install Mutagen:

```bash
brew install mutagen-io/mutagen/mutagen  # macOS, Linux
scoop install main/mutagen               # Windows
```

Binaries without a package manager: [releases](https://github.com/mutagen-io/mutagen/releases/latest).

Make a key without a passphrase, since Mutagen runs unattended:

```bash
ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519_cubby"
```

Put `~/.ssh/id_ed25519_cubby.pub` on the server as `data/clients/<name>.pub` (your name, which also names your private folder, see [Private folders](#6-private-folders)), then restart the server, see [Clients: add, revoke](#5-clients-add-revoke).

Add to `~/.ssh/config`:

```text
Host cubby
    HostName SERVER_IP
    Port 2222
    User cubby
    IdentityFile ~/.ssh/id_ed25519_cubby
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

`Port` is your `CUBBY_PORT` if you set one. The keepalives drop a dead connection, after a network change or sleep, within 45 seconds, so Mutagen reconnects instead of waiting on it.

Create the session. On the first connect, compare the fingerprint ssh shows with the server log.

```bash
mutagen sync create --name=cubby /path/to/local/folder cubby:/shared
```

Day to day:

```bash
mutagen sync list cubby         # status
mutagen sync terminate cubby    # remove the session, files stay
mutagen daemon stop             # any mutagen command starts it again
```

On Linux with the systemd unit, stop the daemon with `systemctl --user stop mutagen.service` instead: the unit restarts a stopped daemon.

Deletions propagate within seconds, the backups are the safety net. Conflicts are never resolved by discarding data: edit the side you want to keep.

## 3. Daemon on boot and alerts

Windows, macOS, at login:

```bash
mutagen daemon register
```

Linux, at boot:

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

Alerts: a notification when a session stays disconnected, halted, conflicted or failing for over a minute.

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

<details><summary>Linux (untested)</summary>

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

<details><summary>macOS (untested)</summary>

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

macOS asks once to allow notifications from Script Editor.

</details>

## 4. Backups

The backup container snapshots `data/shared/` into `data/backups/` at start and every `CUBBY_BACKUP_INTERVAL` in which something changed. Snapshots are hardlinked, so unchanged files cost only a directory entry, `data/backups/latest` points at the newest and the oldest beyond `CUBBY_BACKUP_KEEP` are removed. With the defaults, hourly and 168 kept, a deletion stays recoverable for at least a week, longer when nothing changes, a larger `CUBBY_BACKUP_KEEP` is cheap.

```bash
docker compose ps  # backup, backup-private show unhealthy after two missed intervals or under 1 GiB free
docker compose logs -f backup
ls data/backups/
```

Restore by unpacking a snapshot into the container as the sync user, the copy syncs to every client. `flock` (util-linux) locks `data/backups` while `tar` reads: the restore makes new snapshots, and their pruning waits until it ends, so even the oldest snapshot stays readable.

> [!CAUTION]
> Never copy into `data/shared/` as root: a client can plant a symlink there.

```bash
sudo flock data/backups tar -C data/backups/2026-09-03T030000Z -cf - some/folder | docker compose exec -T -u 1000:1000 server tar -C /shared -xf -
```

While the lock is held, the backup log says `pruning postponed` and the next run catches up. To keep a snapshot for good, rename it to anything but a timestamp: only timestamp names are pruned.

Offsite copy: pull from another machine, `rsync -aHS server:/path/cubby/data/backups/ backups/`. `data/private-backups/` is readable only by root.

## 5. Clients: add, revoke

Add: drop the device's `.pub` into `data/clients/`. Revoke: delete it. Then:

```bash
docker compose restart server  # other clients reconnect on their own
```

> [!WARNING]
> Deleting `<name>.pub` also deletes its [private folder](#6-private-folders) at that restart, its snapshots keep it until they are pruned. To block a key and keep the folder, replace or empty the file's contents instead.

## 6. Private folders

Each `data/clients/<name>.pub` also gets `/private/<name>`, readable only by the keys in that file.

> [!TIP]
> **To share a private folder, put several keys in one `.pub`, one key per line.** For example:
>
> ```
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
mutagen sync create --name=family /path/to/family/folder family@cubby:/private/family
```

> [!WARNING]
> Keep the local folder apart from the `cubby` session's folder, not inside or around it: Mutagen merges them and copies private files into `/shared`.

`backup-private` snapshots the folders into `data/private-backups/`. To rename, `mv` both the `.pub` and `data/private/<name>` before restarting.

Each folder's uid:

```bash
(cd data/private && stat -c '%u  %n' -- *)
# 2000  victus-laptop-1
# 2001  msi-work-laptop-1
```

> [!CAUTION]
> Never restore a private folder as root: a client can plant a symlink there.

Restore as that uid, under the lock on `data/private-backups`, as in [Backups](#4-backups):

```bash
sudo flock data/private-backups tar -C data/private-backups/2026-09-03T030000Z -cf - laptop/some/folder | docker compose exec -T -u <uid>:1000 server tar -C /private -xf -
```

## 7. SFTP

Copy single files or folders without a sync session. A push overwrites the server's file and Mutagen spreads it to every device, overwritten or deleted files come back only from [backups](#4-backups). The server has no rsync, only OpenSSH.

On a computer, use the key and `cubby` alias from [Client](#2-client):

```bash
scp cubby:/shared/some/file .              # pull
scp -r folder cubby:/shared/some/          # push
sftp cubby                                 # interactive, cd /shared
scp file laptop@cubby:/private/laptop/     # private folder, logged in as its name
```

Android and iOS: any SFTP app with key login, server `SERVER_IP`, port `2222` (or `CUBBY_PORT`). Shared folder: user `cubby`, path `/shared`. Private folder: user `<name>`, path `/private/<name>`. On first connect, compare the fingerprint the app shows with the server log.

Without `ssh-keygen`, make an Ed25519 key pair in the browser at [sshkeygen.dev](https://sshkeygen.dev), or [maxotto-agent.github.io/sshkeygen](https://maxotto-agent.github.io/sshkeygen/) if it is down. Import the private key into the app and register the `.pub` as in [Clients: add, revoke](#5-clients-add-revoke).

## 8. Web

Read `/shared` from any browser, no key or install: a plain read-only "Index of /" with a `download` link per file (symlinks, dotfiles and names that are not valid UTF-8 are not listed), behind a password and a one-time code. Off by default.

Uncomment `COMPOSE_PROFILES=web` in `.env` to include it in every `docker compose` command, then start it and show the credentials:

```bash
docker compose up --build -d
docker compose exec web /entrypoint.sh show  # password, seed, otpauth link
```

The first start writes the credentials to `data/web/credentials`, never to the log. Add the seed to an authenticator app. Rotate: delete that file, `docker compose restart web`, run `show` again.

Log in with the browser's sign-in box: any username (even empty), the four words and the 6-digit code with nothing between, `orbit-velvet-cannon-shrug492817`. Each code works once and a login is remembered for 15 minutes per IP. Three wrong attempts block that IP for 1 hour, and requests are capped at 10 per second. A restart clears both.

Nginx serves plain HTTP on `127.0.0.1:8080` (`CUBBY_WEB_BIND_ADDR`, `CUBBY_WEB_PORT`), put one HTTPS proxy or tunnel in front. It must pass `Authorization` and set `X-Forwarded-For`, and Cubby trusts only the last entry, so a second proxy in a row is not supported. Without the header all visitors share one IP, and one lockout.

> [!CAUTION]
> Never publish the port beyond the proxy: with `CUBBY_WEB_BIND_ADDR=0.0.0.0` a client could forge `X-Forwarded-For` and get fresh attempts for every guess.

## 9. Maintenance

Update, also monthly for Alpine and OpenSSH security fixes: a plain `--build` reuses the cached `apk add` layer and never gets them.

```bash
git pull
docker compose build --pull --no-cache
docker compose up -d
```

Rotate the host key:

```bash
docker compose down
sudo rm -rf data/config/ssh_host_keys
docker compose up -d
docker compose logs server | grep 'Host key fingerprint'
```

Then on every client: `ssh-keygen -R '[SERVER_IP]:2222'`, with your `CUBBY_PORT` if you set one.

## 10. Layout

```text
server/    sshd image, its entrypoint creates the users and keys from data/clients/ at each start
backup/    snapshot image, also the healthcheck (section 4)
web/       opt-in read-only browser view: nginx with njs, behind password and one-time code (section 8)
client/    alert.sh (Linux, macOS) and alert.ps1 (Windows): notify when a sync stops (section 3)
test/      smoke test of the images and alerts: sh test/test.sh (needs Docker, ssh and ssh-keygen)
data/      runtime state, git-ignored
  config/            ssh_host_keys/ (back it up) and Mutagen's working state
  clients/           <name>.pub, one per client or shared folder (section 5)
  shared/            the synced tree, owned by uid 1000
  private/           <name>/ folders, one uid each from 2000 (section 6)
  backups/           snapshots of shared/, latest points to the newest
  private-backups/   snapshots of private/
  web/               web view credentials, plain text (0600), only with the web profile
```
