# Android Setup (Termux)

**NO ROOT NEEDED**

Run the cubby client on Android using [Termux](https://termux.dev). Mutagen has no Android build, but its generic linux/arm64 binary is a static Go executable and runs fine under `termux-chroot` (a wrapper shipped with the `proot` package), which intercepts the binary's system calls (via `ptrace`) and remaps standard Linux paths like `/tmp` and `/etc` to their Termux equivalents. Android lacks those paths, so the stock Mutagen build would fail without it. Bare `proot` sets up no such bindings; always go through `termux-chroot`.

> [!IMPORTANT]
> Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or its [GitHub releases](https://github.com/termux/termux-app/releases/latest), **not the Play Store**, whose build is outdated and cannot execute downloaded binaries.

## Quick install

If you want to go straight forward, run this command:

```bash
apt update && apt -y -o Dpkg::Options::=--force-confnew full-upgrade && apt -y install curl && curl -fsSL https://raw.githubusercontent.com/jannoguer/cubby/main/client/android/setup.sh | bash
```

The script walks through the same steps below, prompting for the server address and pausing while you register the key on the server. `CUBBY_SERVER_IP` and `CUBBY_SERVER_PORT` environment variables skip the prompts.

## Installation

### 1. Base packages

openssh provides both ssh-keygen and the ssh client Mutagen uses as transport; the proot package ships termux-chroot, which fakes the Linux paths the binary expects. The dpkg option answers config-file prompts with the maintainer's version so the upgrade runs unattended.

```bash
pkg update -y && pkg upgrade -y -o Dpkg::Options::=--force-confnew
pkg install -y openssh curl proot
```

### 2. Download the latest Mutagen linux/arm64 build

```bash
VERSION=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/mutagen-io/mutagen/releases/latest)")
curl -fL -o mutagen.tar.gz "https://github.com/mutagen-io/mutagen/releases/download/${VERSION}/mutagen_linux_arm64_${VERSION}.tar.gz"
```

### 3. Install into Termux's bin

The agent bundle must sit next to the binary: Mutagen looks for mutagen-agents.tar.gz in its own directory when connecting to the server.

```bash
tar -xzf mutagen.tar.gz -C "$PREFIX/bin" mutagen mutagen-agents.tar.gz
rm mutagen.tar.gz
termux-chroot mutagen version
```

### 4. Generate the SSH key

No passphrase: the daemon reconnects in the background with no TTY or agent, so it cannot decrypt a protected key.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -N "" -f ~/.ssh/cubby
```

### 5. Register the key on the server

Print the public key, add it on the server as e.g. `keys/phone.pub`, then run `docker compose restart` there.

```bash
cat ~/.ssh/cubby.pub
```

### 6. Add the host alias

**Edit the SERVER_IP line before running.**

```bash
SERVER_IP=192.168.1.10
cat >> ~/.ssh/config <<EOF
Host cubby
    HostName ${SERVER_IP}
    Port 2222
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

### 7. Accept the server host key

```bash
ssh cubby true
```

### 8. Grant storage access

Accept the Android permission dialog; this creates the ~/storage symlinks, with ~/storage/shared pointing to /storage/emulated/0. The loop waits for the grant so the mkdir cannot run first and create a plain directory in Termux home instead of shared storage.

```bash
termux-setup-storage
until [ -L ~/storage/shared ]; do sleep 1; done
mkdir -p ~/storage/shared/Cubby
```

### 9. Start the daemon and create the sync session

Shared storage makes the files visible to every Android app, but is case-insensitive and supports neither inotify (Mutagen falls back to polling: slower, more battery) nor symlinks or POSIX permissions. If syncs misbehave, retarget to a folder inside Termux's home (e.g. ~/cubby) instead.

```bash
termux-chroot mutagen daemon run > /dev/null 2>&1 &
termux-chroot mutagen sync create --name=Cubby --ignore=/.cubby ~/storage/shared/Cubby cubby:/shared
termux-chroot mutagen sync list
```

## Syncing

The daemon does not survive Termux being killed, so it runs on demand rather than persistently. Every time you want to sync, just run:

```bash
termux-chroot mutagen daemon run > /dev/null 2>&1 &
```

Check progress and conflicts with `termux-chroot mutagen sync list`. While a sync should stay running in the background, acquire a wake lock with `termux-wake-lock` (ships with Termux, adds a persistent notification) and exclude Termux from battery optimization (Settings > Apps > Termux > Battery > Unrestricted).

## Always-On Sync (OPTIONAL)

For a permanently connected client that survives reboots, install the [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) add-on, open it once, then create the boot script below. Boot scripts run after the first unlock following a reboot, and the wake lock plus battery exemption from the previous section are still required or Android will suspend the daemon. Network drops need nothing extra: a running daemon reconnects its sessions automatically.

```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-mutagen.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
# Supervisor: "daemon run" blocks while the daemon is healthy, so the loop
# only spins when it dies, relaunching it 30 seconds later. (If a daemon is
# already running, "daemon run" exits immediately and the loop just idles.)
while true; do
  termux-chroot mutagen daemon run > /dev/null 2>&1
  sleep 30
done &
EOF
chmod +x ~/.termux/boot/start-mutagen.sh
```

On Android 12+, the "phantom process killer" terminates app child processes under load, taking the daemon down despite the wake lock. Disable it once via adb from a PC (see [this Termux issue](https://github.com/termux/termux-app/issues/2366) for details and per-Android-version variants):

```bash
adb shell "settings put global settings_enable_monitor_phantom_procs false"
```
