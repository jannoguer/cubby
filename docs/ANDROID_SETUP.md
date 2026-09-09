# Android

**NO ROOT NEEDED.** Two options: browse and upload on demand with any SFTP app, or sync continuously with Mutagen in Termux.

## On demand: SFTP app

The server is plain SFTP on port `2222`, user `syncuser`, key auth only. Generate an ed25519 key in the app (or import one), put its public key on the server as `keys/phone.pub` (chmod 644) and connect. Files appear immediately; nothing runs in the background.

## Continuous: Termux

Mutagen's linux/arm64 binary runs in [Termux](https://termux.dev) under `termux-chroot`. Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or [GitHub](https://github.com/termux/termux-app/releases/latest), not the Play Store.

Have the server's host key fingerprint at hand (`docker compose logs cubby | grep 'Host key fingerprint'`), then run in Termux:

```bash
apt update && apt -y -o Dpkg::Options::=--force-confnew full-upgrade && apt -y install curl && curl -fsSL https://raw.githubusercontent.com/jannoguer/cubby/main/client/android/setup.sh | bash
```

[setup.sh](../client/android/setup.sh) installs Mutagen, creates the key, prompts for the server, verifies the host key, installs the daemon as a [termux-services](https://wiki.termux.com/wiki/Termux-services) service and creates the `Cubby` session in `~/storage/shared/Cubby`. Overrides: `CUBBY_SERVER_IP`, `CUBBY_SERVER_PORT`, `CUBBY_HOST_FINGERPRINT`, `CUBBY_MUTAGEN_VERSION`.

Daemon: `sv status mutagen`, `sv restart mutagen`; log in `$PREFIX/var/log/sv/mutagen/current`. Session: `termux-chroot mutagen sync list`. Syncing stops when Android kills Termux: set Termux to Unrestricted battery and run `termux-wake-lock` for long syncs. Shared storage is case-insensitive and polled; if syncs misbehave, recreate the session against `~/cubby`.

## Start at boot (optional)

Install [Termux:Boot](https://f-droid.org/packages/com.termux.boot/), open it once, then:
```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-services.sh <<'EOS'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
. $PREFIX/etc/profile.d/start-services.sh
EOS
chmod +x ~/.termux/boot/start-services.sh
```
Android 12+ may still kill the daemon; disable the phantom process killer once via adb ([details](https://github.com/termux/termux-app/issues/2366)):
```bash
adb shell "settings put global settings_enable_monitor_phantom_procs false"
```
