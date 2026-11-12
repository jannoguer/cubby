# Cubby

Self-hosted file sync. One Alpine container runs a key-only sshd, every computer runs [Mutagen](https://mutagen.io) (tested with v0.18.1) against it, phones copy over [SFTP](#7-sftp), and two more containers keep hardlinked snapshots where no client key can reach them.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop and the desktop, and you stop thinking about it. I wanted that feeling without relying on Dropbox, or watching it add features nobody asked for every quarter.

1. [Server](#1-server)
2. [Client](#2-client)
3. [Daemon on boot and alerts](#3-daemon-on-boot-and-alerts)
4. [Backups](#4-backups)
5. [Clients: add, revoke](#5-clients-add-revoke)
6. [Private folders](#6-private-folders)
7. [SFTP](#7-sftp)
8. [Maintenance](#8-maintenance)
9. [Layout](#9-layout)

## 1. Server

Needs Docker with Compose and TCP `2222` (or `CUBBY_PORT`) reachable by the clients. Docker skips ufw.

```bash
git clone https://github.com/jannoguer/cubby.git cubby && cd cubby
mkdir -p data/config data/shared data/clients data/backups data/private-backups
sudo chown 1000:1000 data/backups
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

Make a key, pressing Enter twice for no passphrase:

```bash
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_cubby"
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

Deletions propagate within seconds; the backups are the safety net. Conflicts are never resolved by discarding data: edit the side you want to keep.

## 3. Daemon on boot and alerts

Windows, macOS, at login:

```bash
mutagen daemon register
```

Linux, at boot:

```bash
mkdir -p ~/.config/systemd/user
curl -fsSL -o /tmp/mutagen.service https://raw.githubusercontent.com/jannoguer/cubby/main/client/linux/mutagen.service && sed "s|^ExecStart=mutagen|ExecStart=$(command -v mutagen)|" /tmp/mutagen.service > ~/.config/systemd/user/mutagen.service
mutagen daemon stop
systemctl --user enable --now mutagen.service
loginctl enable-linger "$USER"
systemctl --user status mutagen.service
```

Alerts: a notification when a session stays disconnected, halted, conflicted or failing for over a minute.

Windows:

```powershell
New-Item -ItemType Directory -Force $HOME\.local\bin | Out-Null
Invoke-WebRequest https://raw.githubusercontent.com/jannoguer/cubby/main/client/windows/alert.ps1 -OutFile $HOME\.local\bin\cubby-alert.ps1
$action = New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$HOME\.local\bin\cubby-alert.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask cubby-alert -Action $action -Trigger $trigger -Settings $settings -Force
```

Linux, macOS:

```bash
mkdir -p ~/.local/bin && curl -fsSL -o ~/.local/bin/cubby-alert https://raw.githubusercontent.com/jannoguer/cubby/main/client/alert.sh && chmod +x ~/.local/bin/cubby-alert
(crontab -l 2>/dev/null | grep -v cubby-alert; echo '*/5 * * * * $HOME/.local/bin/cubby-alert') | crontab -
```

macOS asks once to allow notifications from Script Editor.

## 4. Backups

The backup container snapshots `data/shared/` into `data/backups/` at start and every `CUBBY_BACKUP_INTERVAL` in which something changed. Snapshots are hardlinked, so unchanged files cost only a directory entry; `data/backups/latest` points at the newest and the oldest beyond `CUBBY_BACKUP_KEEP` are removed. With the defaults, hourly and 168 kept, a deletion stays recoverable for at least a week, longer when nothing changes; a larger `CUBBY_BACKUP_KEEP` is cheap.

```bash
docker compose ps  # backup, backup-private show unhealthy after two missed intervals or under 1 GiB free
docker compose logs -f backup
ls data/backups/
```

Restore by unpacking a snapshot into the container as the sync user; the copy syncs to every client. Never copy into `data/shared/` as root: a client can plant a symlink there.

Rename an older snapshot before restoring from it: the restore is itself a change, so the next snapshot can prune the oldest, and only timestamp names are pruned. Leave the newest alone, `latest` points at it. Rename it back or delete it when done.

```bash
sudo mv data/backups/2026-09-03T030000Z data/backups/keep
sudo tar -C data/backups/keep -cf - some/folder | docker compose exec -T -u 1000:1000 server tar -C /shared -xf -
```

Offsite copy: pull from another machine, `rsync -aHS server:/path/cubby/data/backups/ backups/`. `data/private-backups/` is readable only by root.

## 5. Clients: add, revoke

Add: drop the device's `.pub` into `data/clients/`. Revoke: delete it. Then:

```bash
docker compose restart server  # other clients reconnect on their own
```

## 6. Private folders

Each `data/clients/<name>.pub` also gets `/private/<name>`, readable only by the keys in that file.

**ONE `.pub` CAN HOLD SEVERAL KEYS, ONE PER LINE: EVERY KEY IN IT SHARES THE FOLDER.** For example:

```
data/clients/ana.pub       ana's key
data/clients/parents.pub   ana's and ben's keys
data/clients/family.pub    ana's, ben's and eva's keys
```

- ana sees `/shared`, `/private/ana`, `/private/parents` and `/private/family`
- ben sees `/shared`, `/private/parents` and `/private/family`
- eva sees `/shared` and `/private/family`

Naming rules: `a-z`, `0-9`, `_`, `-`, up to 32, not starting with `-`, not a system account such as `cubby`, `root` or `guest`. If a name breaks them, the server log says why it skipped the folder.

Log in as the folder's name to sync it:

```bash
mutagen sync create --name=family /path/to/family/folder family@cubby:/private/family
```

> [!WARNING]
> Keep the local folder apart from the `cubby` session's folder, not inside or around it: Mutagen merges them and copies private files into `/shared`.

Revoking keeps the folder. `backup-private` snapshots it into `data/private-backups/`.

Each folder's uid:

```bash
(cd data/private && stat -c '%u  %n' -- *)
# 2000  victus-laptop-1
# 2001  msi-work-laptop-1
```

Restore as that uid, NEVER AS ROOT, renaming the snapshot first as in [Backups](#4-backups):

```bash
sudo mv data/private-backups/2026-09-03T030000Z data/private-backups/keep
sudo tar -C data/private-backups/keep -cf - laptop/some/folder | docker compose exec -T -u <uid>:1000 server tar -C /private -xf -
```

## 7. SFTP

Copy single files or folders without a sync session. A push overwrites the server's file and Mutagen spreads it to every device; overwritten or deleted files come back only from [backups](#4-backups). The server has no rsync, only OpenSSH.

On a computer, use the key and `cubby` alias from [Client](#2-client):

```bash
scp cubby:/shared/some/file .              # pull
scp -r folder cubby:/shared/some/          # push
sftp cubby                                 # interactive; cd /shared
scp file laptop@cubby:/private/laptop/     # private folder, logged in as its name
```

Android and iOS: any SFTP app with key login, server `SERVER_IP`, port `2222` (or `CUBBY_PORT`). Shared folder: user `cubby`, path `/shared`. Private folder: user `<name>`, path `/private/<name>`. On first connect, compare the fingerprint the app shows with the server log.

Without `ssh-keygen`, make an Ed25519 key pair in the browser at [sshkeygen.dev](https://sshkeygen.dev), or [maxotto-agent.github.io/sshkeygen](https://maxotto-agent.github.io/sshkeygen/) if it is down. Import the private key into the app and register the `.pub` as in [Clients: add, revoke](#5-clients-add-revoke).

## 8. Maintenance

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

## 9. Layout

```text
server/    sshd image; server/entrypoint.sh builds users and authorized_keys at start
backup/    snapshot image; backup/entrypoint.sh loops and is the healthcheck
client/    alert.sh, windows/alert.ps1, linux/mutagen.service
test/      smoke test of both images: sh test/test.sh, needs Docker and ssh
data/      runtime state, ignored by git
  config/            ssh_host_keys/ (back it up) and the sync users' homes, Mutagen's working state
  clients/           <device>.pub, read at start
  shared/            the synced tree; contents owned by uid 1000
  private/           <name>/ per client file, each owned by its own uid from 2000 up
  backups/           snapshots named <UTC timestamp>Z, latest is a symlink to the newest
  private-backups/   the same for private/
```
