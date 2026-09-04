# Android Setup (Termux)

**NO ROOT NEEDED**

Mutagen's linux/arm64 binary runs in [Termux](https://termux.dev) under `termux-chroot`. Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or [GitHub](https://github.com/termux/termux-app/releases/latest), not the Play Store.

## Install

Have the server's host key fingerprint at hand (`docker compose logs cubby | grep 'Host key fingerprint'`), then run in Termux:

```bash
apt update && apt -y -o Dpkg::Options::=--force-confnew full-upgrade && apt -y install curl && curl -fsSL https://raw.githubusercontent.com/jannoguer/cubby/main/client/android/setup.sh | bash
```

[setup.sh](../client/android/setup.sh) installs Mutagen, creates the key, prompts for the server, verifies the host key and creates the `Cubby` session in `~/storage/shared/Cubby`. Overrides: `CUBBY_SERVER_IP`, `CUBBY_SERVER_PORT`, `CUBBY_HOST_FINGERPRINT`, `CUBBY_MUTAGEN_VERSION`.

## Syncing

The daemon dies with Termux; start it whenever you want to sync:
```bash
termux-chroot mutagen daemon run > /dev/null 2>&1 &
```
Status: `termux-chroot mutagen sync list`. For long syncs run `termux-wake-lock` and set Termux to Unrestricted battery. Shared storage is case-insensitive and polled; if syncs misbehave, recreate the session against `~/cubby`.

## Always-On (optional)

Install [Termux:Boot](https://f-droid.org/packages/com.termux.boot/), open it once, then:
```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-mutagen.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
while true; do termux-chroot mutagen daemon run > /dev/null 2>&1; sleep 30; done &
EOF
chmod +x ~/.termux/boot/start-mutagen.sh
```
Android 12+ may still kill the daemon; disable the phantom process killer once via adb ([details](https://github.com/termux/termux-app/issues/2366)):
```bash
adb shell "settings put global settings_enable_monitor_phantom_procs false"
```
