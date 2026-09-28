# Cubby

Self-hosted file sync. One Alpine container runs a key-only sshd, every device runs [Mutagen](https://mutagen.io) (tested with v0.18.1) against it, and a second container keeps hardlinked snapshots where no client key can reach them.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop, the desktop, the phone, and you stop thinking about it. I wanted that feeling on hardware I own, without a subscription, an account, or a platform that grows unnecessary features every quarter.

1. [Server](#1-server)
2. [Client](#2-client)
3. [Daemon on boot](#3-daemon-on-boot)
4. [Backups](#4-backups)
5. [Clients: add, revoke](#5-clients-add-revoke)
6. [Maintenance](#6-maintenance)
7. [Layout](#7-layout)

Android: [client/android](client/android/README.md).

## 1. Server

Needs Docker with Compose and TCP `2222` reachable by the clients. Docker skips ufw.

```bash
git clone https://github.com/jannoguer/cubby.git cubby && cd cubby
mkdir -p data/config data/shared data/clients data/backups
sudo chown 1000:1000 data/backups
docker compose up --build -d
docker compose logs server | grep 'Host key fingerprint'
```

Optional settings: `cp .env.example .env` and uncomment what you need.

| Variable | Default | Meaning |
|---|---|---|
| `CUBBY_BIND_ADDR` | `0.0.0.0` | Address Docker publishes port 2222 on. |
| `CUBBY_BACKUP_INTERVAL` | `3600` | Seconds between snapshots. |
| `CUBBY_BACKUP_KEEP` | `168` | Snapshots kept; an interval with no changes writes none. |

Back up `data/config/`: it holds the host key.

## 2. Client

Install Mutagen:

```bash
brew install mutagen-io/mutagen/mutagen # macOS, Linux
scoop install main/mutagen              # Windows
```

Binaries without a package manager: [releases](https://github.com/mutagen-io/mutagen/releases/latest).

Make a key:

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/cubby
```

Put `~/.ssh/cubby.pub` on the server as `data/clients/<device>.pub`, then restart the server, see [Clients: add, revoke](#5-clients-add-revoke).

Add to `~/.ssh/config`:

```text
Host cubby
    HostName SERVER_IP
    Port 2222
    User cubby
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
```

Create the session. On the first connect, compare the fingerprint ssh shows with the server log.

```bash
mutagen sync create --name=cubby /path/to/local/folder cubby:/shared
mutagen sync list
```

Day to day:

```bash
mutagen sync monitor cubby      # live status
mutagen sync flush cubby        # sync now
mutagen sync pause cubby        # stop syncing, keep the session
mutagen sync resume cubby
mutagen sync terminate cubby    # remove the session, files stay
```

Deletions propagate within seconds; the backups are the safety net. Conflicts are never resolved by discarding data: edit the side you want to keep.

Private folder (optional): every `data/clients/<name>.pub` also gets `/private/<name>`, which only the keys in that file can open; other keys can see the folder's name, never its contents. A `.pub` holding several keys, one per line, makes a folder shared by just those devices. The name must be lowercase letters, digits, `_` and `-`, up to 32; the server log prints `Private folder /private/<name> (uid N)` or why it was skipped. For `data/clients/laptop.pub`, sync it with a second session that logs in as `laptop`:

```bash
mutagen sync create --name=private /path/to/private/folder laptop@cubby:/private/laptop
```

Alert (optional, Linux and macOS): every 15 minutes cron runs [client/alert.sh](client/alert.sh), which pushes one message to a URL when a session stays disconnected, halted, conflicted or with problems for over a minute. It pushes again only when the problem changes, never on recovery, and ignores paused sessions. Any URL that takes a POST works, such as an [ntfy](https://ntfy.sh) topic (pick a long random name, it is the only secret); `mutagen sync list` shows the details. On a first crontab, `crontab -l` printing "no crontab" is expected.

```bash
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/cubby-alert https://raw.githubusercontent.com/jannoguer/cubby/main/client/alert.sh && chmod +x ~/.local/bin/cubby-alert
(crontab -l; echo "*/15 * * * * PATH=$(dirname "$(command -v mutagen)"):/usr/bin:/bin $HOME/.local/bin/cubby-alert https://ntfy.sh/YOUR_TOPIC") | crontab -
```

## 3. Daemon on boot

Windows, macOS:

```bash
mutagen daemon register
```

Linux:

```bash
mkdir -p ~/.config/systemd/user
curl -fsSL -o /tmp/mutagen.service https://raw.githubusercontent.com/jannoguer/cubby/main/client/linux/mutagen.service && sed "s|^ExecStart=mutagen|ExecStart=$(command -v mutagen)|" /tmp/mutagen.service > ~/.config/systemd/user/mutagen.service
mutagen daemon stop
systemctl --user enable --now mutagen.service
loginctl enable-linger "$USER"
systemctl --user status mutagen.service
```

## 4. Backups

The backup container snapshots `data/shared/` into `data/backups/` at start and every `CUBBY_BACKUP_INTERVAL` in which something changed, so `CUBBY_BACKUP_KEEP` counts changes, not hours. Snapshots are hardlinked, so unchanged files cost no space; `data/backups/latest` points at the newest and the oldest beyond `CUBBY_BACKUP_KEEP` are removed.

```bash
docker compose ps # backup, backup-private show unhealthy after two missed intervals
docker compose logs -f backup
ls data/backups/
```

Restore by unpacking a snapshot into the container as the sync user; the copy syncs to every client. Never copy into `data/shared/` or `data/private/` as root: a client can plant a symlink there.

```bash
sudo tar -C data/backups/2026-09-03T030000Z -cf - some/folder | docker compose exec -T -u 1000:1000 server tar -C /shared -xf -
```

Private folders are snapshotted the same way into `data/private-backups/` by `backup-private`, which runs as root with only the right to read. Restore as the folder's owner, here `laptop` with uid 2000 from the server log:

```bash
sudo tar -C data/private-backups/2026-09-03T030000Z -cf - laptop/some/folder | docker compose exec -T -u 2000:1000 server tar -C /private -xf -
```

Offsite copy: pull from another machine, `rsync -aH server:/path/cubby/data/backups/ backups/`.

## 5. Clients: add, revoke

Add: drop the device's `.pub` into `data/clients/`. Revoke: delete it. A `.pub` can hold several keys, one per line. Revoking keeps `data/private/<name>/`; adding the same name again reopens it. Then:

```bash
docker compose restart server # other clients reconnect on their own
```

## 6. Maintenance

Update:

```bash
git pull
docker compose up --build -d
```

Rotate the host key:

```bash
docker compose down
sudo rm -rf data/config/ssh_host_keys
docker compose up -d
docker compose logs server | grep 'Host key fingerprint'
```

Then on every client: `ssh-keygen -R '[SERVER_IP]:2222'`.

## 7. Layout

```text
server/    sshd image; server/entrypoint.sh builds the users and authorized_keys at start
backup/    snapshot image; backup/entrypoint.sh loops and is the healthcheck
client/    alert.sh, linux/mutagen.service, android/install.sh and its README
data/      runtime state, ignored by git
  config/    host key and the sync user's home; back it up
  clients/   <device>.pub, read at start
  shared/    the synced tree; contents owned by uid 1000
  private/   <name>/ per client file, each owned by its own uid from 2000 up; Docker creates it
  backups/   snapshots named <UTC timestamp>Z, latest is a symlink to the newest
  private-backups/  the same for private/, root-owned; Docker creates it
```
