# Cubby

A barebones, self-hosted file sync server utilizing a minimal Alpine container running only `sshd` with key-only access. Syncing is handled by [Mutagen](https://mutagen.io) (built and tested against v0.18.1) over SSH.

For the Android client, see [Android Setup (Termux)](docs/ANDROID_SETUP.md).

## 1. Installation & Server Setup

### Client

**Install Mutagen:**
```bash
brew install mutagen-io/mutagen/mutagen # macOS/Linux
scoop install main/mutagen              # Windows
```
or grab a prebuilt binary from the [releases page](https://github.com/mutagen-io/mutagen/releases/latest).

**Generate SSH Key:**
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/cubby
```

### Server

**Initialize:** Clone this repo in your target directory and ensure TCP port `2222` is open on your server/VPS provider. Create the directories, add your key, stage the client helpers, and start the container:
```bash
mkdir -p config shared keys
echo "PASTE_YOUR_CLIENT_PUB_KEY" > keys/laptop.pub
mkdir -p shared/.cubby_client
cp -rf client/. shared/.cubby_client/
docker compose up --build -d
```

> [!NOTE]
> The copy into `shared/.cubby_client` distributes the client helpers (watch scripts, systemd unit) to every device on its first sync; later sections reference them from there. Skipping it only costs you those helpers.

> [!NOTE]
> `keys/` holds one `.pub` file per client (e.g., `laptop.pub`, `desktop-3.pub`); other files are ignored. Run `docker compose restart` after adding or deleting keys.

> [!IMPORTANT]
> `./config` holds the SSH host key and the sync user's home, **back this up**.


## 2. Configuration & Syncing

**SSH Config:** Add this host alias to `~/.ssh/config` so Mutagen can read it:

```text
Host cubby
    HostName SERVER_IP
    Port 2222
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
```

**Create Sync Session:** Start syncing with the following command:
```bash
mutagen sync create --name=Cubby --ignore=/.cubby /path/to/local/folder cubby:/shared
```

> [!NOTE]
> The `--ignore` flag reserves the `.cubby` folder used by optional watch scripts, preventing their marker files from propagating to the server or other clients.

**Start Daemon on Boot:** (RECOMMENDED)
* **Windows/macOS:** Run `mutagen daemon register`.
* **Linux:** `daemon register` is [not supported](https://mutagen.io/documentation/introduction/daemon/#system-management).
    
    Use the provided unit instead. It arrives with the first sync (staged into `shared/.cubby_client` during server setup), so wait for the session to settle, then:
    ```bash
    mkdir -p ~/.config/systemd/user
    cp .cubby_client/linux/mutagen.service ~/.config/systemd/user/
    systemctl --user enable --now mutagen.service
    ```
    *(Note: Run `loginctl enable-linger $USER` on headless machines so the daemon starts at boot)*.


## 3. Managing Syncs & Conflicts

Run `mutagen sync list` to check sessions status and conflicts.

> [!CAUTION] 
> The default `two-way-safe` mode never auto-resolves a conflict in a way that loses data. Resolve listed conflicts by editing the side you want to keep, then let it re-sync.


## 4. Health and Conflict Markers (OPTIONAL)

Every client already has schedulable probe scripts in `.cubby_client/` inside the sync root (staged there during server setup). They write machine-readable health and conflict markers under `.cubby/`; check their header comments for usage, cron/Task Scheduler examples, and exit codes. Keep `watch-common.ps1` next to the scripts; they dot-source it.

```bash
pwsh -NoProfile -File .cubby_client/watch-status.ps1 Cubby
```
