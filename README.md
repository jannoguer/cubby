# cubby

A barebones, self-hosted file sync server utilizing a minimal Alpine container running only `sshd` with key-only access. Syncing is handled by [Mutagen](https://mutagen.io) (built and tested against v0.18.1) over SSH.

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
ssh-keygen -t ed25519 -f ~/.ssh/cubby
```

### Server

**Initialize:** Clone this repo in your target directory and ensure TCP port `2222` is open on your server/VPS provider. Create the directories, add your key, and start the container:
```bash
mkdir -p config shared keys
echo "PASTE_YOUR_CLIENT_PUB_KEY" > keys/laptop.pub
docker compose up --build -d
```

> [!NOTE]
> `keys/` holds one `.pub` file per client (e.g., `laptop.pub`, `desktop-3.pub`); other files are ignored. Run `docker compose restart` after adding or deleting keys.

> [!NOTE]
> Synced files live in `./shared` (mounted at `/shared`).

> [!NOTE]
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
mutagen sync create --name=cubby --ignore=/.cubby /path/to/local/folder cubby:/shared
```

> [!NOTE]
> The `--ignore` flag reserves the `.cubby` folder used by optional watch scripts, preventing their marker files from propagating to the server or other clients.

**Start Daemon on Boot:** (RECOMMENDED)
* **Windows/macOS:** Run `mutagen daemon register`.
* **Linux:** `daemon register` is [not supported](https://mutagen.io/documentation/introduction/daemon/#system-management).
    
    Use the provided unit instead:
    ```bash
    mkdir -p ~/.config/systemd/user
    cp mutagen.service ~/.config/systemd/user/
    systemctl --user enable --now mutagen.service
    ```
    *(Note: Run `loginctl enable-linger $USER` on headless machines so the daemon starts at boot)*.


## 3. Managing Syncs & Conflicts

Run `mutagen sync list` to check sessions status and conflicts.

> [!CAUTION] 
> The default `two-way-safe` mode never auto-resolves a conflict in a way that loses data. Resolve listed conflicts by editing the side you want to keep, then let it re-sync.


## 4. Health and Conflict Markers (OPTIONAL)

The `client/` folder ships with schedulable probe scripts (check their header comments for cron/Task Scheduler examples and exit codes):

* **`watch-status.ps1 <session>`:** Writes `.cubby/status.ok` or `.cubby/status.err` with machine-readable session health.

* **`watch-conflicts.ps1 <session>`:** Maintains `.cubby/conflicts.json` while conflicts exist, removing it when clean.

* **`run-hidden.vbs <command>`:** A Windows helper (`wscript` GUI-subsystem app) that runs arguments with no visible window. This keeps Task Scheduler from flashing a console during an interactive logon and returns the exit code.

> [!TIP]
> To sync these scripts across all clients automatically, place them in a hidden folder:

```bash
mkdir -p shared/.cubby_scripts
cp -rf client/. shared/.cubby_scripts/
```
