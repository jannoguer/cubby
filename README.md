# Cubby

Self-hosted file sync. One Alpine container runs a key-only `sshd`, every device runs [Mutagen](https://mutagen.io) (tested with v0.18.1) against it, and a second container keeps hardlinked snapshots where no client key can reach them. Sync, backups and health checks are on by default; notifications and offsite mirroring are opt-in.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop, the desktop, the phone, and you stop thinking about it. I wanted that feeling on hardware I own, without a subscription, an account, or a platform that grows unnecessary features every quarter.

1. [Server](#1-server)
2. [Client](#2-client)
3. [Daemon on boot](#3-daemon-on-boot)
4. [Health and notifications](#4-health-and-notifications)
5. [Backups](#5-backups)
6. [Clients: add, revoke](#6-clients-add-revoke)
7. [Maintenance](#7-maintenance)
8. [Layout](#8-layout)

Android: [docs/ANDROID_SETUP.md](docs/ANDROID_SETUP.md).

## 1. Server

Needs Docker with Compose and TCP `2222` reachable by the clients.

```bash
git clone https://github.com/jannoguer/cubby.git cubby && cd cubby
mkdir -p config shared keys backups offsite
sudo chown 1000:1000 backups
echo "PASTE_CLIENT_PUB_KEY" > keys/work-laptop-2.pub # one .pub per device
docker compose up --build -d
docker compose logs cubby | grep 'Host key fingerprint'
```

Optional settings: `cp .env.example .env` and uncomment what you need.

| Variable | Default | Meaning |
|---|---|---|
| `CUBBY_BIND_ADDR` | `0.0.0.0` | Address to publish `2222` on. Docker bypasses `ufw`, so bind to a VPN or LAN IP when exposed. |
| `BACKUP_INTERVAL` | `3600` | Seconds between snapshots. |
| `BACKUP_KEEP_HOURLY` / `_DAILY` / `_WEEKLY` | `24` / `14` / `8` | Snapshots kept per tier. |
| `NTFY_URL` | empty | ntfy topic URL for push notifications. |
| `BACKUP_REMOTE` / `BACKUP_REMOTE_PORT` | empty / `22` | Offsite mirror target, `user@host:/path`. |

Back up `config/`: it holds the host key. Files placed into `shared/` from the host need `sudo chown -R 1000:1000 shared/<path>`.

## 2. Client

Install Mutagen and make a key:

```bash
brew install mutagen-io/mutagen/mutagen # macOS, Linux
scoop install main/mutagen              # Windows
ssh-keygen -t ed25519 -N "" -f ~/.ssh/cubby
```

Binaries without a package manager: [releases](https://github.com/mutagen-io/mutagen/releases/latest). Put `~/.ssh/cubby.pub` on the server as `keys/<device>.pub`.

Add to `~/.ssh/config`:

```text
Host cubby
    HostName SERVER_IP
    Port 2222
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
```

Create the session. On the first connect, compare the fingerprint ssh shows with the server log.

```bash
mutagen sync create --name=Cubby --ignore=/.cubby/local /path/to/local/folder cubby:/shared
mutagen sync list
```

Day to day:

```bash
mutagen sync monitor Cubby      # live status
mutagen sync flush Cubby        # sync now
mutagen sync pause Cubby        # stop syncing, keep the session
mutagen sync resume Cubby
mutagen sync terminate Cubby    # remove the session, files stay
```

Deletions propagate within seconds; the backups are the safety net. Conflicts are never resolved by discarding data: edit the side you want to keep.

## 3. Daemon on boot

Windows, with rotating logs in `.cubby/local/logs/mutagen.log` (use instead of `mutagen daemon register`):

```powershell
pwsh -NoProfile -File .cubby\client\daemon.ps1 -Register C:\path\to\local\folder
```

macOS:

```bash
mutagen daemon register
```

Linux:

```bash
mkdir -p ~/.config/systemd/user
cp .cubby/client/linux/mutagen.service ~/.config/systemd/user/
systemctl --user enable --now mutagen.service
loginctl enable-linger $USER    # headless machines
journalctl --user -u mutagen -f # logs
```

## 4. Health and notifications

`watch.ps1` checks the session once and writes into `.cubby/local/`: `status.ok` or `status.err` (sync health plus the server's backup summary), `conflicts.json` when there are conflicts, and a line in `logs/watch.log`. Exit code 0 means healthy, 2 unhealthy, 1 nothing written.

```bash
pwsh -NoProfile -File .cubby/client/watch.ps1 Cubby
```

Schedule it every minute:

```text
cron:            * * * * * pwsh -NoProfile -File /path/to/.cubby/client/watch.ps1 Cubby
Task Scheduler:  wscript.exe C:\path\to\.cubby\client\run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\.cubby\client\watch.ps1 Cubby
```

**Notifications.** Set `NTFY_URL` in the server's `.env` to a topic such as `https://ntfy.sh/<long-random-name>` and subscribe to it in the ntfy app. The URL reaches every client through the synced backup marker; nothing else to configure. Pushed on change only:

- Server: backup failed, partial or recovered; offsite copy failed or recovered.
- Each client running `watch.ps1`: sync unhealthy or healthy again, conflicts appearing or resolved, backups stale or running again. Messages carry the session and machine name.

Clients trust the synced URL only when it is https on `ntfy.sh`. For a self-hosted ntfy, or to override the topic on one client, set the `CUBBY_NTFY_URL` environment variable.

## 5. Backups

The backup container snapshots `shared/` into `backups/` at start and every `BACKUP_INTERVAL`. Snapshots are hardlinked, so unchanged files cost no space; `backups/latest` points at the newest. Retention keeps the newest snapshot of each of the last 24 hours, the first of each of the last 14 days and the first of each of the last 8 ISO weeks. Unreadable paths are skipped and logged; the snapshot is kept with `lastResult=partial`.

```bash
docker compose ps                   # backup shows unhealthy after two missed intervals
docker compose logs -f backup
cat shared/.cubby/backup/status.ok  # or status.err
```

Restore, from the compose directory:

```bash
backup/restore.sh list                                  # all snapshots
backup/restore.sh list some/folder                      # snapshots holding that path
sudo backup/restore.sh restore 2026-09-03T030000Z some/folder
sudo backup/restore.sh restore -f latest some/file.txt  # -f replaces an existing path
```

**Offsite copy.** Safest is to pull from another machine, so the server holds no credentials and a compromised server cannot erase the copy: `rsync -aH server:/path/backups/ backups/`. Alternatively the server mirrors `backups/` after every snapshot with `rsync -aH --delete`, hardlinks intact. It is a mirror: pruning and deletions propagate. Set `BACKUP_REMOTE=user@host:/path` in `.env`, then:

```bash
ssh-keygen -t ed25519 -N "" -f offsite/id_ed25519
ssh-keyscan -p 22 host > offsite/known_hosts
sudo chown -R 1000:1000 offsite
docker compose up -d
```

Install `offsite/id_ed25519.pub` on the remote. Failures appear as `offsite=rsync-N` in `status.ok` and are pushed through ntfy.

## 6. Clients: add, revoke

Add: drop the device's `.pub` into `keys/`. The file name (letters, digits, `.` `_` `-`) is the client's name in the server log. No restart needed.

Revoke: delete the file. Every open session is cut within a second; the remaining clients reconnect on their own.

```bash
docker compose logs -f cubby    # "Key revoked: work-laptop-2; ended 3 process(es), other clients reconnect."
```

## 7. Maintenance

Update:

```bash
git pull
docker compose up --build -d
```

Rotate the host key:

```bash
docker compose down
rm -rf config/ssh_host_keys
docker compose up -d
docker compose logs cubby | grep 'Host key fingerprint'
```

Then on every client: `ssh-keygen -R '[SERVER_IP]:2222'`.

Logs: `docker compose logs -f cubby` and `docker compose logs -f backup` on the server (10 MB, three files each); `.cubby/local/logs/` on each client.

## 8. Layout

```text
config/            host key; back it up
keys/              <device>.pub, served live
shared/            the synced tree; contents owned by uid 1000
  .cubby/client/   helper scripts, refreshed from the image at every start
  .cubby/backup/   status.ok|err from the backup container, synced to every client
  .cubby/local/    this device's markers and logs, never synced
backups/           snapshots named <UTC timestamp>Z, plus latest ->
offsite/           ssh key and known_hosts for the mirror, owned by uid 1000
```
