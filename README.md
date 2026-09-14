# Cubby

Self-hosted file sync on [Syncthing](https://syncthing.net). One always-on Debian peer receives every change, passes it on to the other devices and keeps old versions where no device can reach them. Every device runs the stock Syncthing package; nothing custom sits on the sync path.

**Why:** The best part of Dropbox is forgetting it exists. Files land on the laptop, the desktop, the phone, and you stop thinking about it. I wanted that on hardware I own, without a subscription, an account, or a platform that grows features every quarter.

1. [Server](#1-server)
2. [Devices](#2-devices)
3. [Add, revoke](#3-add-revoke)
4. [Conflicts and old versions](#4-conflicts-and-old-versions)
5. [Maintenance](#5-maintenance)
6. [Layout](#6-layout)

Android: [docs/ANDROID.md](docs/ANDROID.md).

## 1. Server

Debian stable, root, TCP `22000` reachable by the devices (LAN or VPN; discovery and relays are off).

```bash
git clone https://github.com/jannoguer/cubby.git && cd cubby
sudo server/cubby install
```

Asks for the admin UI password (or generates one) and prints the server's device ID. The folder is `/srv/cubby/Cubby`, receive-only with staggered versioning: a year of old versions by default. Settings are listed at the top of [server/cubby](server/cubby) and saved to `/etc/default/cubby`; change one by rerunning install with it set, for example `sudo env CUBBY_MAX_AGE_DAYS=0 cubby install` to keep versions forever.

Admin UI: `ssh -L 8384:127.0.0.1:8384 SERVER`, then `http://127.0.0.1:8384`, user `admin`.

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

Then in the device's UI at `http://127.0.0.1:8384`:

1. Actions > Show ID. Give it to the server: `sudo cubby add NAME DEVICE-ID`.
2. Add Remote Device: the server's ID, name `cubby`, Advanced > Addresses `tcp://SERVER_IP:22000`.
3. Accept the offered `Cubby` folder, set its path (for example `~/Cubby`), and paste [client/stignore](client/stignore) under Ignore Patterns.

Files sync from then on. Syncthing 2 on a device talks to Syncthing 1 on the server. The UI is the status page; the tray icon is optional.

## 3. Add, revoke

```bash
sudo cubby add laptop XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX
sudo cubby remove laptop
sudo cubby status
```

Removal disconnects the device immediately. No restart, no keys to rotate.

## 4. Conflicts and old versions

The same file edited on two devices yields `name.sync-conflict-DATE-TIME-DEVICE.ext` beside the original, on every device. Keep the one you want.

Every version replaced or deleted from any device is kept on the server under `/srv/cubby/Cubby/.stversions/`, timestamped, for `CUBBY_MAX_AGE_DAYS`. Copy one back into the folder to restore it, or use the folder's Versions button in the server UI. The versions directory is never synced, so no device can alter it.

Files written directly on the server never propagate; `cubby status` counts them as changed on the server, and the folder's Revert button in the UI discards them.

## 5. Maintenance

- `sudo cubby health` runs every ten minutes from cron and prints only when the disk is over 85 percent, the folder is in error, items fail to sync, or a device has been away for a week; cron mails root when it prints.
- Updates: `apt upgrade` on the server, the package manager on each device. Syncthing keeps protocol compatibility across versions.
- Offsite copy: from another machine, `rsync -a SERVER:/srv/cubby/Cubby/ /backup/cubby/` on a cron line. Pull-based; the server holds no credential.
- Back up `/srv/cubby/.config/syncthing/`: it holds the server's identity. Losing it means re-adding the server on every device.

## 6. Layout

```text
server/cubby        install, configure, add, remove, status, health
client/stignore     ignore patterns for every device
docs/ANDROID.md     phone setup
```

Server: `/srv/cubby/Cubby` folder, `/srv/cubby/.config/syncthing` identity and config, `/etc/default/cubby` settings, `syncthing@cubby.service`, `/etc/cron.d/cubby`, `/usr/local/bin/cubby`.
