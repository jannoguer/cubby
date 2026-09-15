# Cubby

Self-hosted file sync. One Alpine container runs a key-only `sshd`, every device runs [Mutagen](https://mutagen.io) (tested with v0.18.1) against it, and a second container keeps hardlinked snapshots where no client key can reach them.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop, the desktop, the phone, and you stop thinking about it. I wanted that feeling on hardware I own, without a subscription, an account, or a platform that grows unnecessary features every quarter.

1. [Server](#1-server)
2. [Client](#2-client)
3. [Daemon on boot](#3-daemon-on-boot)
4. [Backups](#4-backups)
5. [Clients: add, revoke](#5-clients-add-revoke)
6. [Maintenance](#6-maintenance)
7. [Layout](#7-layout)

Android: [docs/ANDROID_SETUP.md](docs/ANDROID_SETUP.md).

## 1. Server

Needs Docker with Compose and TCP `2222` reachable by the clients.

```bash
git clone https://github.com/jannoguer/cubby.git cubby && cd cubby
mkdir -p config shared keys backups
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
| `BACKUP_KEEP` | `168` | Snapshots kept. |

Back up `config/`: it holds the host key.

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
mutagen sync create --name=Cubby /path/to/local/folder cubby:/shared
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

Windows, macOS:

```bash
mutagen daemon register
```

Linux:

```bash
mkdir -p ~/.config/systemd/user
curl -fsSLo ~/.config/systemd/user/mutagen.service https://raw.githubusercontent.com/jannoguer/cubby/main/client/linux/mutagen.service
systemctl --user enable --now mutagen.service
loginctl enable-linger $USER    # headless machines
journalctl --user -u mutagen -f # logs
```

## 4. Backups

The backup container snapshots `shared/` into `backups/` at start and every `BACKUP_INTERVAL`. Snapshots are hardlinked, so unchanged files cost no space; `backups/latest` points at the newest and the oldest beyond `BACKUP_KEEP` are removed.

```bash
docker compose ps # backup shows unhealthy after two missed intervals
docker compose logs -f backup
ls backups/
```

Restore by copying out of a snapshot; the copy syncs to every client:

```bash
sudo cp -a backups/2026-09-03T030000Z/some/folder shared/some/
```

Offsite copy: pull from another machine, `rsync -aH server:/path/backups/ backups/`.

## 5. Clients: add, revoke

Add: drop the device's `.pub` into `keys/`. Revoke: delete it. Then:

```bash
docker compose restart cubby # other clients reconnect on their own
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
rm -rf config/ssh_host_keys
docker compose up -d
docker compose logs cubby | grep 'Host key fingerprint'
```

Then on every client: `ssh-keygen -R '[SERVER_IP]:2222'`.

## 7. Layout

```text
config/    host key; back it up
keys/      <device>.pub, read at start
shared/    the synced tree; contents owned by uid 1000
backups/   snapshots named <UTC timestamp>Z, latest is a symlink to the newest
```
