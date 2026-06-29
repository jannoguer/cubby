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
mutagen sync create --name=cubby /path/to/local/folder cubby:/shared
```

Run `mutagen sync list` to check status and conflicts.

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
> The default `two-way-safe` mode never auto-resolves a conflict in a way that
> loses data. Resolve listed conflicts by editing the side you want to keep,
> then let it re-sync.
