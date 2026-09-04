# Cubby

Self-hosted file sync: an Alpine container running key-only `sshd`, [Mutagen](https://mutagen.io) (tested with v0.18.1) on the clients, and a second container snapshotting the data where clients cannot reach it. Android client: [docs/ANDROID_SETUP.md](docs/ANDROID_SETUP.md).

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
docker compose up --build -d
docker compose logs cubby | grep 'Host key fingerprint'
```

- `keys/`: one world-readable `.pub` per client. Changes apply live, no restart.
- `shared/.cubby/`: `client/` (helpers, overwritten from the image at every start), `backup_status.ok|err` (written by the backup container), `local/` (each client's own markers, never synced).
- Files added to `shared/` from the host need `sudo chown -R 1000:1000 shared/<path>`.
- Back up `config/`: it holds the host key.
- Docker publishes past `ufw`. To bind elsewhere or tune backups, copy `.env.example` to `.env`.

## Sync

`~/.ssh/config`:
```text
Host cubby
    HostName SERVER_IP
    Port 2222
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
```
```bash
mutagen sync create --name=Cubby --ignore=/.cubby/local /path/to/local/folder cubby:/shared
mutagen sync list
```
Compare the fingerprint ssh shows with the server log. In Git Bash prefix the command with `MSYS_NO_PATHCONV=1`. Deletions propagate within seconds; the backups are the safety net. Conflicts are never resolved with data loss: edit the side to keep.

**Daemon on boot.**

Windows/macOS:
```bash
mutagen daemon register
```

Linux:
```bash
mkdir -p ~/.config/systemd/user
cp .cubby/client/linux/mutagen.service ~/.config/systemd/user/
systemctl --user enable --now mutagen.service
loginctl enable-linger $USER # on headless machines
```

**Health markers (optional).** Writes `status.ok|err` (sync health plus backup summary) and `conflicts.json` into `.cubby/local/`; the script header has fields, scheduling and exit codes.
```bash
pwsh -NoProfile -File .cubby/client/watch.ps1 Cubby
```

## Backups

Hardlinked snapshots of `shared/` in `backups/` at start and every `BACKUP_INTERVAL` seconds (default one day), keeping `BACKUP_KEEP` (default 14); `backups/latest` is the newest. Copy offsite with `rsync -aH`. `docker compose ps` shows the container unhealthy after two missed intervals. Restore:
```bash
sudo cp -a backups/2026-09-03T030000Z/some/folder shared/some/
sudo chown -R 1000:1000 shared/some/folder
```

## Maintenance

Update:
```bash
git pull
docker compose up --build -d
```
Add a client: drop its `.pub` into `keys/`. Revoke: delete it; its open session is cut within a second and the other clients reconnect.

Rotate the host key: stop the stack, delete `config/ssh_host_keys/`, start it and note the new fingerprint. On every client: `ssh-keygen -R '[SERVER_IP]:2222'`.
