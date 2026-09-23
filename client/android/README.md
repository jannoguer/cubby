# Android

**NO ROOT NEEDED.** Syncs continuously with Mutagen in Termux.

## Install

Mutagen's linux/arm64 binary runs in [Termux](https://termux.dev) under `termux-chroot`. Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or [GitHub](https://github.com/termux/termux-app/releases/latest), not the Play Store.

Have the server's host key fingerprint at hand (`docker compose logs server | grep 'Host key fingerprint'`), then run in Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/jannoguer/cubby/main/client/android/install.sh | bash
```

[install.sh](install.sh) upgrades Termux's packages, installs Mutagen, creates the key, prompts for the server, verifies the host key, installs the daemon as a [termux-services](https://wiki.termux.com/wiki/Termux-services) service and creates the `cubby` session in `~/storage/shared/Cubby`. Overrides: `CUBBY_SERVER_IP`, `CUBBY_SERVER_PORT`, `CUBBY_HOST_FINGERPRINT`, `CUBBY_MUTAGEN_VERSION`.

Daemon: `sv status mutagen`, `sv restart mutagen`; log in `$PREFIX/var/log/sv/mutagen/current`. If the daemon has stopped and the service is not bringing it back, start it by hand: `termux-chroot mutagen daemon run > /dev/null 2>&1 &`. Session: `termux-chroot mutagen sync list`. Syncing stops when Android kills Termux: set Termux to Unrestricted battery and run `termux-wake-lock` for long syncs. Shared storage is case-insensitive and polled; if syncs misbehave, recreate the session against `~/cubby`.

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
