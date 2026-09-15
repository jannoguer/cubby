# Cubby

Self-hosted file sync on [Syncthing](https://syncthing.net). One always-on peer receives every change, passes it on to the other devices and keeps old versions where no device can reach them. The server is a container; every device runs the stock Syncthing package. Nothing custom sits on the sync path, and everything is administered from a terminal.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop, the desktop, the phone, and you stop thinking about it. I wanted that on hardware I own, without a subscription, an account, or a platform that grows features every quarter.

1. [Server](#1-server)
2. [Devices](#2-devices)
3. [Add, revoke](#3-add-revoke)
4. [Conflicts and old versions](#4-conflicts-and-old-versions)
5. [Maintenance](#5-maintenance)
6. [Layout](#6-layout)

Android: [docs/ANDROID.md](docs/ANDROID.md).

## 1. Server

Any host with Docker and TCP `22000` reachable by the devices (LAN or VPN; discovery and relays are off). The container brings its own Syncthing, so the host's distribution, packages and users do not come into it.

```bash
git clone https://github.com/jannoguer/cubby.git && cd cubby
cp .env.example .env     # optional; the defaults below are what you get without it
docker compose up -d
docker compose logs | grep 'cubby: device ID'
```

That last line prints the server's device ID, which the devices need. The synced folder is `./data`, receive-only with staggered versioning: a year of old versions by default. The server's identity, config and database are in `./config`.

Settings live in `.env` and are documented in [.env.example](.env.example): where the two directories sit on the host, which uid owns the files, how long versions are kept. After changing one, `docker compose up -d` applies it. Files are written as `PUID:PGID`, 1000 by default; set it to the account that should be able to read them directly, and the container re-owns what is already there on the next start.

The sync port is the only thing listening on the network. The Syncthing API is on a unix socket inside the container that nothing outside it reaches, so there is no web UI, no port and no password to keep.

Administration runs through the container:

```bash
docker exec cubby cubby status
alias cubby='docker exec cubby cubby'   # then just: cubby status
```

Coming from an earlier, non-containerized install: copy the old `/srv/cubby/.config/syncthing/` into `./config/` before the first `up`, and the server keeps its device ID, so the devices need no change.

## 2. Devices

Install Syncthing and make it start at login:

```bash
sudo apt install syncthing && systemctl --user enable --now syncthing.service   # Linux
brew install syncthing && brew services start syncthing                        # macOS
winget install Syncthing.Syncthing                                             # Windows, then in a new terminal:
```

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Syncthing.lnk")
$s.TargetPath = (Get-Command syncthing).Source; $s.Arguments = '--no-console --no-browser'; $s.Save()
Start-Process syncthing -ArgumentList '--no-console --no-browser'
```

Then, in a terminal on the device, with the server's device ID and address:

```bash
syncthing device-id                                       # give this to the server: cubby add NAME DEVICE-ID
syncthing cli config devices add --device-id SERVER-ID --name cubby --addresses tcp://SERVER-IP:22000
syncthing cli config folders add --id cubby --label Cubby --path $HOME/Cubby
syncthing cli config folders cubby devices add --device-id SERVER-ID
scp SERVER:cubby/client/stignore $HOME/Cubby/.stignore      # or copy client/stignore there any other way
```

Files sync from then on; `syncthing cli show connections` lists the server as connected. The server runs Syncthing 2; a device on either 1 or 2 talks to it.

Optionally, once it works, switch off the device's web UI. It takes effect at the next Syncthing start:

```bash
syncthing cli config gui enabled set false
```

The REST API goes with it, so `syncthing cli` stops working on that device. To change something later, set `enabled="true"` on the `<gui>` line of `config.xml` (`syncthing paths` prints where it is; `syncthing --paths` on Syncthing 1), restart Syncthing, run the commands, and switch it off again.

## 3. Add, revoke

```bash
docker exec cubby cubby add laptop XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX
docker exec cubby cubby remove laptop     # or the device ID
docker exec cubby cubby status
```

Removal disconnects the device immediately. No restart, no keys to rotate.

## 4. Conflicts and old versions

The same file edited on two devices yields `name.sync-conflict-DATE-TIME-DEVICE.ext` beside the original, on every device. Keep the one you want.

Every version replaced or deleted from any device is kept on the server under `data/.stversions/`, timestamped, for `CUBBY_MAX_AGE_DAYS`. To restore one, copy it from the server into the folder on any device. The versions directory is never synced, so no device can alter it.

Files written directly on the server never propagate: the folder there is receive-only. `cubby status` counts them as changed on the server, and `docker exec cubby cubby revert` deletes them, taking the devices' copies back where they differ.

## 5. Maintenance

- `cubby health` reports only when the disk is over 85 percent, the folder is in error, items fail to sync, or a device has been away for a week. The container runs it every five minutes as its healthcheck, so `docker ps` shows `unhealthy` when something is wrong and `docker inspect --format '{{json .State.Health}}' cubby` prints what it said.
- Updates: `docker compose build --pull && docker compose up -d` on the server, the package manager on each device. Syncthing keeps protocol compatibility across versions.
- Offsite copy: from another machine, `rsync -a SERVER:/path/to/cubby/data/ /backup/cubby/` on a cron line. Pull-based; the server holds no credential.
- Back up `config/`: it holds the server's identity. Losing it means re-adding the server on every device.

## 6. Layout

```text
compose.yaml        ports, volumes and settings for the server
.env.example        the settings, with their defaults and what they do
server/Dockerfile   the image: Syncthing's binary on Alpine, plus the cubby script
server/entrypoint   prepares the directories, starts Syncthing, configures it
server/cubby        add, remove, revert, status, health, id, configure
client/stignore     ignore patterns for every device
docs/ANDROID.md     phone setup
```

On the host: `data/` the synced folder with its `.stversions`, `config/` the identity, config and database, `.env` the settings. Inside the container these are `/srv/cubby/Cubby` and `/srv/cubby/config`, with the API socket at `/run/cubby/api.sock`.
