# cubby

A barebones, self-hosted file sync server: a minimal Alpine container running only `sshd` with key-only access, plus a `shared` folder. Syncing is done by [Mutagen](https://mutagen.io) on each client, over SSH.

## Prerequisites

**Server:** place the project's `Dockerfile`, `docker-compose.yml`, and `entrypoint.sh` in your target directory.

**Client:** install Mutagen and an OpenSSH client (the client ships with Windows 10+, macOS, and Linux):

```bash
brew install mutagen-io/mutagen/mutagen   # macOS / Linux
scoop install main/mutagen                # Windows
```

On Windows you can also grab a [prebuilt binary](https://github.com/mutagen-io/mutagen/releases/latest) from the releases page.

Everything in this project (including the watch scripts) was built and tested against Mutagen 0.18.1.

## Setup

### On the client

Generate an SSH key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/cubby
```

### On the server

Create the directories, drop in the client key, and start:

```bash
mkdir -p config shared keys
echo "PASTE_YOUR_CLIENT_PUB_KEY" > keys/laptop.pub
docker compose up --build -d
```

`keys/` holds one `.pub` file per client, named after the client (`laptop.pub`, `desktop-3.pub`, ...); other files are ignored. After adding (or deleting) a key file you just run `docker compose restart`.

> [!NOTE]
> You may need to open TCP port `2222` on your server or VPS provider.

> [!NOTE]
> Synced files live in `./shared` on the server (mounted at `/shared`). `./config` holds the SSH host key and the sync user's home; back it up.

## Usage

Add a host alias to `~/.ssh/config` (Mutagen reads it):

```
Host cubby
    HostName SERVER_IP
    Port 2222
    User syncuser
    IdentityFile ~/.ssh/cubby
    IdentitiesOnly yes
```

Create the sync session:

```bash
mutagen sync create --name=cubby --ignore=/.cubby /path/to/local/folder cubby:/shared
```

The `--ignore` flag reserves the `.cubby` folder used by the optional watch scripts (see below) so their marker files never propagate to the server or other clients.

Run `mutagen sync list` to check status and conflicts.

### Health and conflict markers (optional)

The `client/` folder ships two probe scripts meant to run on a schedule (cron or Task Scheduler) on each client, along with a Windows helper script:

- `watch-status.ps1 <session>` writes `.cubby/status.ok` or `.cubby/status.err` into the synced folder with machine-readable session health.
- `watch-conflicts.ps1 <session>` maintains `.cubby/conflicts.json` in the synced folder while the session reports conflicts, and removes it when clean.
- `run-hidden.vbs <command>` runs the given command arguments with no visible window and returns the exit code. Because Windows Task Scheduler flashes a console when starting a console app directly under an interactive logon, wrapping the scheduled probes with this `wscript` GUI-subsystem app keeps the runs completely invisible.

The `.cubby` directory in the sync root is reserved: the scripts own its contents, and the session should ignore it (see the create command above). Each script's header comment documents scheduling examples and exit codes.

I personally put those scripts in a hidden folder named `.cubby_scripts/`, that way, the scripts get synced across all clients.

### Start the Mutagen daemon on boot

On macOS and Windows:

```bash
mutagen daemon register
```

On Linux, `daemon register` is [not supported](https://mutagen.io/documentation/introduction/daemon/#system-management); use the provided systemd user unit instead:

```bash
mkdir -p ~/.config/systemd/user
cp mutagen.service ~/.config/systemd/user/
systemctl --user enable --now mutagen.service
```

On a headless machine where no one logs in, also run `loginctl enable-linger $USER` so the user session (and with it the daemon) starts at boot.

> [!CAUTION]
> The default `two-way-safe` mode never auto-resolves a conflict in a way that loses data. Resolve listed conflicts by editing the side you want to keep, then let it re-sync.
