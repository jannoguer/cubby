# Cubby

Self-hosted file sync: an Alpine container running only key-only `sshd`, [Mutagen](https://mutagen.io) (tested with v0.18.1) on the clients, and a second container snapshotting the data where clients cannot reach it. Android client: [docs/ANDROID_SETUP.md](docs/ANDROID_SETUP.md).

## Client

```bash
brew install mutagen-io/mutagen/mutagen # macOS/Linux
scoop install main/mutagen              # Windows
ssh-keygen -t ed25519 -N "" -f ~/.ssh/cubby
```
Prebuilt binaries: [releases page](https://github.com/mutagen-io/mutagen/releases/latest).

## Server

Clone the repo, open TCP `2222`, then:
```bash
mkdir -p config shared keys backups
sudo chown 1000:1000 backups
echo "PASTE_YOUR_CLIENT_PUB_KEY" > keys/laptop.pub
mkdir -p shared/.cubby_client
cp -rf client/. shared/.cubby_client/
docker compose up --build -d
docker compose logs cubby | grep 'Host key fingerprint'
```

- `keys/` holds one `.pub` per client; run `docker compose restart cubby` after changing it.
- `shared/.cubby_client` ships the client helpers (watch scripts, systemd unit) to every device.
- Files added to `shared/` from the host need `sudo chown -R 1000:1000 shared/<path>`; clients cannot change them otherwise.
- Compare the printed fingerprint when a client first connects. Back up `config/`: it holds the host key.
- Docker publishes past `ufw`. To bind elsewhere or tune backups, copy `.env.example` to `.env`.

## Sync

Add to `~/.ssh/config`:
```text
Host cubby
    HostName SERVER_IP
    Port 2222
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
```
```bash
mutagen sync create --name=Cubby --ignore=/.cubby /path/to/local/folder cubby:/shared
mutagen sync list
```
`--ignore=/.cubby` keeps the watch scripts' markers local. Sync propagates deletions everywhere within seconds; the backups below are the safety net. Conflicts are never resolved with data loss: edit the side to keep and let it re-sync.

**Daemon on boot.** Windows/macOS: `mutagen daemon register`. Linux, after the first sync has delivered the helpers:
```bash
mkdir -p ~/.config/systemd/user
cp .cubby_client/linux/mutagen.service ~/.config/systemd/user/
systemctl --user enable --now mutagen.service
loginctl enable-linger $USER # on headless machines
```

**Health markers (optional).** The probe scripts in `.cubby_client/` write status and conflict markers under `.cubby/`; their headers document scheduling and exit codes.
```bash
pwsh -NoProfile -File .cubby_client/watch-status.ps1 Cubby
```

## Backups

`backups/` receives a browsable snapshot of `shared/` at start and every `BACKUP_INTERVAL` seconds (default one day), keeping `BACKUP_KEEP` (default 14); `backups/latest` is the newest. Unchanged files are hardlinks, so snapshots are cheap. They share the host's disk: copy `backups/` offsite to survive it. Restore by copying back and handing the files to the sync user:
```bash
ls backups/
sudo cp -a backups/2026-09-03T030000Z/some/folder shared/some/
sudo chown -R 1000:1000 shared/some/folder
```

## Maintenance

Update (live sessions reconnect on their own):
```bash
git pull
docker compose up --build -d
cp -rf client/. shared/.cubby_client/
```
Add or revoke a client: edit `keys/`, then `docker compose restart cubby`.

Rotate the host key: stop the stack, delete `config/ssh_host_keys/`, start it and note the new fingerprint. On every client:
```bash
ssh-keygen -R '[SERVER_IP]:2222'
```
