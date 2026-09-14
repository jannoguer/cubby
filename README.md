# Cubby

Self-hosted file sync on [Syncthing](https://syncthing.net). One always-on Debian peer receives every change, passes it on to the other devices and keeps old versions where no device can reach them. Every device runs the stock Syncthing package; nothing custom sits on the sync path, and everything is administered from a terminal.

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

Prints the server's device ID. The folder is `/srv/cubby/Cubby`, receive-only with staggered versioning: a year of old versions by default. Settings are listed at the top of [server/cubby](server/cubby) and saved to `/etc/default/cubby`; change one by rerunning install with it set, for example `sudo env CUBBY_MAX_AGE_DAYS=0 cubby install` to keep versions forever.

The sync port is the only thing listening on the network. The script talks to Syncthing over a socket under `/run/cubby` that only root reaches; there is no password to keep.

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
syncthing device-id                                       # give this to the server: sudo cubby add NAME DEVICE-ID
syncthing cli config devices add --device-id SERVER-ID --name cubby --addresses tcp://SERVER-IP:22000
syncthing cli config folders add --id cubby --label Cubby --path $HOME/Cubby
syncthing cli config folders cubby devices add --device-id SERVER-ID
scp SERVER:cubby/client/stignore $HOME/Cubby/.stignore      # or copy client/stignore there any other way
```

Files sync from then on; `syncthing cli show connections` lists the server as connected. Syncthing 2 on a device talks to Syncthing 1 on the server.

Optionally, once it works, switch off the device's web UI. It takes effect at the next Syncthing start:

```bash
syncthing cli config gui enabled set false
```

The REST API goes with it, so `syncthing cli` stops working on that device. To change something later, set `enabled="true"` on the `<gui>` line of `config.xml` (`syncthing paths` prints where it is; `syncthing --paths` on Syncthing 1), restart Syncthing, run the commands, and switch it off again.

## 3. Add, revoke

```bash
sudo cubby add laptop XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX
sudo cubby remove laptop     # or the device ID
sudo cubby status
```

Removal disconnects the device immediately. No restart, no keys to rotate.

## 4. Conflicts and old versions

The same file edited on two devices yields `name.sync-conflict-DATE-TIME-DEVICE.ext` beside the original, on every device. Keep the one you want.

Every version replaced or deleted from any device is kept on the server under `/srv/cubby/Cubby/.stversions/`, timestamped, for `CUBBY_MAX_AGE_DAYS`. To restore one, copy it from the server into the folder on any device. The versions directory is never synced, so no device can alter it.

Files written directly on the server never propagate: the folder there is receive-only. `cubby status` counts them as changed on the server, and `sudo cubby revert` deletes them, taking the devices' copies back where they differ.

## 5. Maintenance

- `sudo cubby health` runs every ten minutes from cron and prints only when the disk is over 85 percent, the folder is in error, items fail to sync, or a device has been away for a week; cron mails root when it prints.
- Updates: `apt upgrade` on the server, the package manager on each device. Syncthing keeps protocol compatibility across versions.
- Offsite copy: from another machine, `rsync -a SERVER:/srv/cubby/Cubby/ /backup/cubby/` on a cron line. Pull-based; the server holds no credential.
- Back up `/srv/cubby/.config/syncthing/`: it holds the server's identity. Losing it means re-adding the server on every device.

## 6. Layout

```text
server/cubby        install, configure, add, remove, revert, status, health
client/stignore     ignore patterns for every device
docs/ANDROID.md     phone setup
```

Server: `/srv/cubby/Cubby` folder, `/srv/cubby/.config/syncthing` identity and config, `/etc/default/cubby` settings, `syncthing@cubby.service`, `/run/cubby/api.sock`, `/etc/cron.d/cubby`, `/usr/local/bin/cubby`.
