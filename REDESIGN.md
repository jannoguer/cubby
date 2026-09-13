# Cubby redesign: git over ssh

Status: proposal. Nothing in this document is implemented. It replaces Mutagen, both containers, the PowerShell clients and the key watcher with tools that are already on every machine: `sshd`, `git`, `ssh`, `bash`, `cron`, `curl`, and optionally `rsync`. No binary is written or shipped.

The document is an implementation plan. Every choice states what is done, why, and what it costs. Edge cases are listed where the code that handles them will live, so the implementer can tick them off.

1. [Requirements](#1-requirements)
2. [The decision](#2-the-decision)
3. [Architecture](#3-architecture)
4. [Server](#4-server)
5. [Client](#5-client)
6. [Cross-platform rules](#6-cross-platform-rules)
7. [Health and notifications](#7-health-and-notifications)
8. [History, restore, offsite](#8-history-restore-offsite)
9. [Optional: one-way rsync trees](#9-optional-one-way-rsync-trees)
10. [Security model](#10-security-model)
11. [Failure catalogue](#11-failure-catalogue)
12. [What is lost](#12-what-is-lost)
13. [Migration](#13-migration)
14. [Tests](#14-tests)
15. [Implementation order](#15-implementation-order)
16. [Deliberately not built](#16-deliberately-not-built)

## 1. Requirements

Everything the current stack does that must survive. Numbered so later sections can point at them.

| # | Requirement | Today |
|---|---|---|
| R1 | One tree, many devices, changes flow in every direction, offline edits merge later. | Mutagen |
| R2 | Key-only ssh. One key per device. Add and revoke without restarting anything. | sshd + AuthorizedKeysCommand + inotifyd killer |
| R3 | Deletions propagate. A conflict never discards data. | Mutagen |
| R4 | Every past version is kept for a long time and can be restored per path. | rsync hardlink snapshots, tiered retention |
| R5 | No client key can read, alter or destroy the history. | Second container, separate volume |
| R6 | Health is visible on each device and on the server without logging in anywhere. | status.ok / status.err markers |
| R7 | Push notifications on state changes only, opt-in. | ntfy |
| R8 | Offsite copy, opt-in, pull preferred so the server holds no credentials. | rsync -aH |
| R9 | Linux, macOS, Windows, Android clients. Start at boot. | pwsh, systemd, runit in Termux |
| R10 | Install is a clone and one script per side. | yes |
| R11 | Only widely used tools. Nothing compiled by this project. | violated by Mutagen |

New requirements this redesign adds:

| # | Requirement | Because |
|---|---|---|
| R12 | Nothing that is synced is ever executed. | Today `.cubby/client` had to be root-owned on the server to keep a client from pushing a script the others run. Remove the class of problem. |
| R13 | A file that cannot exist on one platform must not stall the sync of every other file. | Windows names, symlinks, nested repositories. Dropbox degrades per file; so must Cubby. |
| R14 | No state that differs between platforms may be recorded in the sync. | Anything recorded and platform-dependent ping-pongs forever between two devices. See section 6. |

## 2. The decision

### 2.1 Why not rsync alone

Bidirectional sync needs three things: a transfer, a conflict detector, and a memory of what the tree looked like after the last successful sync. Without the memory, "deleted on the laptop" and "created on the desktop" look identical. rsync has only the transfer. Writing the memory in shell means `find -printf | sort | comm` against a saved listing, a lock, and a three-way decision per path, with the tree changing underneath. That is Unison reimplemented badly. It is not fewer moving parts, only fewer visible ones.

### 2.2 Why git

git is the memory (the index and HEAD), the transfer (pack protocol over ssh), the conflict detector (three-way merge against the merge base), and the history (R4), in one tool that is already installed on every device including Termux and Git for Windows. It gives for free: atomic multi-file changes (other devices never see half of a save that touched three files), rename-aware transfer (a moved 2 GB file is not re-uploaded), offline commits, per-path restore from any device, selective sync (`sparse-checkout`), and a server that cannot lose history when told so by two config lines (R5).

**Decision.** The synced tree is a git working tree. The server is a bare repository behind `sshd`. Every device commits its changes, fetches, merges with a never-auto-merge policy, resolves conflicts by keeping both versions, and pushes.

**Because** it satisfies R1, R3, R4, R5, R11 with zero project-built binaries, and the whole client is one bash script.

**Consequence.** Section 12 lists what git cannot do that Mutagen did: mtimes, empty directories, symlinks, resumable transfer of single huge files, and the cost of permanent history. Section 9 covers the escape hatch for bulk media.

### 2.3 Why not the alternatives

| Alternative | Rejected because |
|---|---|
| Syncthing | A Go binary and its own daemon, protocol and discovery. Violates R11 in the same way Mutagen does, and drops ssh. |
| Unison | The correct classic tool, but OCaml, version-locked between peers, and not in Termux or Git for Windows by default. |
| sshfs / NFS / SFTP mount | Not a sync. No offline copy, no history, one hop of latency per read. |
| rsync with one-way ownership | Works with zero custom logic when each folder has a single writer. It is section 9, not the core, because R1 says the same folder is edited from several machines. |
| git-annex | Solves large files properly. Haskell, its own daemon, its own metadata branch. Violates R11. |
| A Go program | The clean engineering answer and explicitly out of scope. |

### 2.4 Why no containers

The server is one system user, one directory, one sshd drop-in, two hooks and two cron lines. Docker added: a second sshd on 2222 that bypasses `ufw`, capability lists, tmpfs sizes, a healthcheck, a key watcher that kills processes because sshd only checks keys at login, and a second container so that the backup volume is unreachable. In the new design sessions last seconds (a fetch or a push), so revocation needs no killer, and history is protected by git itself, so the second container has no job. Containers stay out. They are allowed for the test suite, where a throwaway `sshd` is convenient.

## 3. Architecture

```text
 laptop                    server (Debian, no containers)             desktop
 ------                    -------------------------------            -------
 ~/Cubby/  (work tree)     sshd :22, Match User cubby                 ~/Cubby/
 ~/Cubby/.git              /etc/cubby/authorized_keys  root-owned     ~/Cubby/.git
   cubby/status              one line per device, restrict,command=
   cubby/logs/             /usr/local/lib/cubby/shell  forced cmd
   info/exclude            /srv/cubby/main.git         bare, hooks:
   info/attributes           pre-receive  (validate)     ----->  ntfy (opt-in)
                             post-receive (log, wake)
 cubby loop  --ssh-->      denyNonFastForwards, denyDeletes   <--ssh--  cubby loop
   (bash, one file)        cron: health, gc, weekly fsck
                                   |
 phone (Termux)                    | pull-based (opt-in)
 ~/storage/shared/Cubby            v
 ~/.cubby/main.git         mirror host: git clone --mirror, cron fetch, fsck
```

Data flow per device, every `cubby.interval` seconds or on a local file event: stage, quarantine, commit, fetch, merge, resolve, push, write status. Section 5.4 has the exact algorithm.

## 4. Server

### 4.1 Packages and versions

Debian stable. `openssh-server`, `git`, `curl`, `cron`. `rsync` only for section 9.

| Tool | Minimum | Because |
|---|---|---|
| OpenSSH | 7.2 | `restrict` in `authorized_keys`. |
| git | 2.30 | `uploadpack.allowFilter`, `init -b`, stable partial clone. Debian 11 ships 2.30, Debian 13 ships 2.47. |
| rsync | 3.2.4 | `rrsync` installed as a command, not a support script. Section 9 only. |

### 4.2 Layout

```text
/etc/cubby/authorized_keys        root:root 0644. One line per device. sshd reads it directly.
/etc/cubby/cubby.conf             root:root 0644. NTFY_URL, NTFY_WAKE_URL, DISK_MIN_FREE_PCT, MAX_FILE_SIZE.
/usr/local/lib/cubby/shell        root:root 0755. Forced command for every key.
/usr/local/lib/cubby/health       root:root 0755. Cron: disk, fsck, mirror age, transitions to ntfy.
/srv/cubby/                       cubby:cubby 0755. Home of the cubby user.
/srv/cubby/main.git/              cubby:cubby. The bare repository.
/srv/cubby/main.git/config        root:root 0644. git never needs to write it; a push cannot change policy.
/srv/cubby/main.git/hooks/        root:root 0755, hooks 0755. Same reason.
/var/lib/cubby/state              cubby:cubby. Last known health, for transition-only notifications.
```

**Why `/etc/cubby/authorized_keys` and not `~cubby/.ssh/authorized_keys`.** The file is root-owned and the cubby user has no shell, so even a bug that gave a client a write somewhere could not add a key. `Match User` sets `AuthorizedKeysFile` to it, so the default location is never consulted.

**Why the repo config and hooks are root-owned.** `git-receive-pack` runs as `cubby`. It writes objects and refs, never `config` or `hooks/`. Owning those as root means a client, which can only ever run `git-receive-pack`, cannot turn off `denyNonFastForwards` even through an unknown git bug that let it write inside the repo.

### 4.3 sshd

`/etc/ssh/sshd_config.d/cubby.conf`:

```text
Match User cubby
    AuthorizedKeysFile /etc/cubby/authorized_keys
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    DisableForwarding yes
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    MaxAuthTries 3
    LogLevel VERBOSE
Match all
```

**Why `Match all` at the end.** Debian's `sshd_config` includes `sshd_config.d/*.conf` on its first line. A `Match` block stays open until the next `Match`, so without the reset every global directive that follows in the main file would be parsed inside `Match User cubby` and sshd would refuse to start with "Directive ... is not allowed within a Match block". `Match all` closes the block. This is a documented sshd idiom, not a trick.

**Why `LogLevel VERBOSE`.** It logs the key fingerprint on every login, so `journalctl -u ssh` plus `ssh-keygen -lf /etc/cubby/authorized_keys` maps every connection to a device name with no code of ours.

**Why port 22 and the host sshd.** One daemon, one host key, one firewall rule, and `ufw` now actually applies (Docker used to bypass it). The `Match` block cannot loosen anything for other users. Nothing about this design needs a second sshd; if the operator wants one on 2222 for policy reasons, the drop-in works unchanged in a second config file.

The user: `useradd --system --home-dir /srv/cubby --shell /bin/sh cubby`. The shell must be a real shell, not `nologin`, because sshd runs the forced command as `$SHELL -c "command"`. The forced command and `restrict` are the restriction, not the shell; see 4.4.

### 4.4 Keys and the forced command

One line per device in `/etc/cubby/authorized_keys`:

```text
restrict,command="/usr/local/lib/cubby/shell laptop" ssh-ed25519 AAAA... laptop
```

`restrict` disables pty, forwarding, X11, agent and `~/.ssh/rc`. `command=` runs the dispatcher with the device name; the client's own command arrives in `SSH_ORIGINAL_COMMAND`.

`/usr/local/lib/cubby/shell`:

```sh
#!/bin/sh
# Forced command for every key in /etc/cubby/authorized_keys. $1 is the device name.
# Only the two git transport commands for the one repository are allowed; git-shell
# then refuses anything that is not a git service. Everything else exits 1.
set -u
export CUBBY_DEVICE=$1
case "${SSH_ORIGINAL_COMMAND-}" in
    "git-upload-pack 'main.git'" | "git-receive-pack 'main.git'")
        exec git-shell -c "$SSH_ORIGINAL_COMMAND" ;;
    *)
        echo "cubby: this key may only sync main.git" >&2
        exit 1 ;;
esac
```

**Why a dispatcher and not `git-shell` as the login shell.** `git-shell` accepts any repository path the user can read. The dispatcher pins the exact command strings git sends (single quotes included, that is what the ssh transport emits for `cubby@host:main.git`), so a key cannot upload-pack `/srv/other.git` or `git-upload-archive` anything. It also exports the device name for the hooks. Ten lines of `case` is the whole thing.

**Why the device name is the argument and not `hostname`.** The server must name the device from something a client cannot forge. The name lives in a root-owned file, next to the key it belongs to.

**Why `command=` per key and not a `ForceCommand` in the Match block.** `ForceCommand` supersedes `command=`, and then the device name would have to be recovered through `ExposeAuthInfo` and a lookup. Per-key `command=` is the pattern gitolite and GitHub made universal; anyone who reads the file understands it.

Add a device: append a line, no restart. Revoke: delete the line, no restart. A session in flight ends on its own within seconds; `pkill -u cubby` is available if a multi-gigabyte clone must be cut now. The whole key watcher, its state file and its five-pass kill loop are gone (R2).

Names: `[A-Za-z0-9._-]+`, enforced by the install helper, because the name is unquoted inside `command="..."`.

### 4.5 The repository

```sh
git init -q --bare -b main /srv/cubby/main.git
cd /srv/cubby/main.git
git config receive.denyNonFastForwards true   # R5: no history rewrite through a push
git config receive.denyDeletes true           # R5: main cannot be deleted
git config receive.fsckObjects true           # malformed trees, .git path components, bad modes: rejected at the door
git config receive.maxInputSize 4g            # one push cannot fill the disk; hooks cap single files lower
git config uploadpack.allowFilter true        # clients clone --filter=blob:none (5.2)
git config core.logAllRefUpdates true         # bare repos default to no reflog; keep one
git config gc.reflogExpire never
git config gc.reflogExpireUnreachable never   # the reflog is the operator's undo for their own mistakes
git config gc.pruneExpire 2.weeks.ago         # objects from failed pushes do get collected
git config user.name cubby
git config user.email cubby@localhost
# One empty root commit, so every clone has a main to merge with.
tree=$(git hash-object -t tree /dev/null)
git update-ref refs/heads/main "$(git commit-tree "$tree" -m init)"
```

**Why an initial commit.** A clone of an empty repository has no `main`, and the client would need a special first-push path. One empty commit removes a whole branch of client code.

**Why `receive.maxInputSize` at 4 GiB and the per-file cap at 2 GiB (4.6).** The pack cap bounds a single hostile or accidental push. The file cap exists because git does not resume an interrupted push; a 10 GB file over a laptop's Wi-Fi restarts from zero every time. Files above the cap belong in section 9.

### 4.6 pre-receive

Rejects a push that would break a client. Runs in under a second for ordinary pushes; a first push of 100k files takes a few seconds, once.

```sh
#!/bin/sh
# stdin: "old new ref" per updated ref. Any non-zero exit rejects the whole push,
# and everything on stderr reaches the client prefixed "remote:".
set -u
zero=0000000000000000000000000000000000000000
max=$(git config --get cubby.maxFileSize || echo 2147483648)
fail() { echo "cubby: rejected: $1" >&2; exit 1; }

while read -r old new ref; do
    [ "$ref" = refs/heads/main ] || fail "only main is synced, not $ref"
    [ "$new" != "$zero" ] || fail "main cannot be deleted"

    # Rules on the final tree only (a client that fixed a bad name in a later commit passes).
    git ls-tree -r -z "$new" | tr '\0' '\n' | awk -v q="'" '
        $1 == "120000" { print "symlink: " substr($0, index($0, "\t") + 1); bad = 1 }
        $1 == "160000" { print "nested repository: " substr($0, index($0, "\t") + 1); bad = 1 }
        END { exit bad }' >&2 || fail "see above; the client excludes these itself, this is the backstop"

    git ls-tree -r --name-only -z "$new" | tr '\0' '\n' | awk '
        {
            n = split($0, c, "/")
            for (i = 1; i <= n; i++) {
                if (c[i] ~ /[<>:"|?*\\]/ || c[i] ~ /[\001-\037]/ || c[i] ~ /[. ]$/ ||
                    toupper(c[i]) ~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$/ || length(c[i]) > 255)
                    { print "invalid on Windows: " $0; bad = 1; break }
            }
        }
        END { exit bad }' >&2 || fail "see above"

    dups=$(git ls-tree -r --name-only -z "$new" | tr '\0' '\n' | tr 'A-Z' 'a-z' | sort | uniq -d)
    [ -z "$dups" ] || fail "paths differ only by case, impossible on macOS and Windows: $dups"

    # Rule on new objects: single-file size cap.
    range="$new"; [ "$old" = "$zero" ] || range="$old..$new"
    git rev-list --objects "$range" | git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' \
        | awk -v m="$max" '$1 == "blob" && $2 > m { print "file over cubby.maxFileSize: " $3; bad = 1 } END { exit bad }' >&2 \
        || fail "see above; put files this large in an rsync tree (REDESIGN.md section 9)"
done
```

**Why the tree rules look at the final tree but the size rule looks at every new object.** A bad name fixed by a later local commit should not block forever; only the end state matters for names. A huge blob is in the pack whether or not the final tree still references it, so it must be caught per object. The client mirrors the same size rule before committing (5.5), and if a manual `git commit` slipped one in, the client's recovery is to squash its unpushed commits (5.4 step 7), which drops the blob.

**Why reject other refs.** The client only ever touches `main`. A stray `git push --all` or a tag from someone using git by hand would otherwise sit on the server as noise that no device ever sees.

**Why the Windows rules on the server at all, since clients exclude them first.** A client set up by hand, or an older script, is the failure mode. The server is the single place every path passes through. The case-collision check is ASCII-only on purpose: Unicode case folding differs between macOS and Windows and neither `tr` nor `awk` can be trusted to agree with either; it catches the common case and states its limit.

### 4.7 post-receive

```sh
#!/bin/sh
set -u
. /etc/cubby/cubby.conf
zero=0000000000000000000000000000000000000000
while read -r old new ref; do
    [ "$ref" = refs/heads/main ] || continue
    if [ "$old" = "$zero" ]; then stat=initial; else stat=$(git diff --shortstat "$old" "$new"); fi
    logger -t cubby "push from ${CUBBY_DEVICE:-unknown}: ${stat:-no file changes}"
    # Optional fast wake for the other devices (7.3). The body is only the device name.
    [ -z "${NTFY_WAKE_URL:-}" ] || curl -fsS -m 10 -d "${CUBBY_DEVICE:-unknown}" "$NTFY_WAKE_URL" > /dev/null \
        || logger -t cubby "wake notification failed"
done
```

Nothing else runs on receive. There is no server-side checkout of the tree in the core design; section 9 and 16 discuss the optional read-only view.

### 4.8 Cron

```text
*/10 * * * *  cubby  /usr/local/lib/cubby/health
30 4 * * 0    cubby  git -C /srv/cubby/main.git gc --quiet
```

`health` (section 7.2) checks free disk, runs `git fsck --connectivity-only` daily and a full `git fsck` weekly by looking at a stamp file, and reports transitions to ntfy. `gc.auto` also packs after receives; the weekly `gc` is for the reflog and the pack count.

### 4.9 Install

`server/install.sh`, idempotent, run as root from a clone of this repository:

1. Install packages if missing.
2. Create the user and `/srv/cubby`, `/etc/cubby`, `/var/lib/cubby`.
3. Copy `shell`, `health`, hooks; chmod and chown as in 4.2.
4. Create the bare repository if absent and apply 4.5. Always re-apply the config so a version upgrade of Cubby updates policy.
5. Write the sshd drop-in, run `sshd -t`, reload sshd only if the test passes.
6. Print the host key fingerprints (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) and the two commands for adding a key.

Key management is two documented one-liners, not a tool:

```sh
# add
printf 'restrict,command="/usr/local/lib/cubby/shell %s" %s %s\n' laptop "$(cut -d' ' -f1-2 laptop.pub)" laptop >> /etc/cubby/authorized_keys
# revoke
sed -i '/ laptop$/d' /etc/cubby/authorized_keys
# list
ssh-keygen -lf /etc/cubby/authorized_keys
```

`install.sh` validates the file after edits with `ssh-keygen -lf`, the same check the entrypoint does today, because a malformed line silently locks out that device.

## 5. Client

### 5.1 Layout

The client is one bash script, `client/cubby`, installed outside the synced tree (R12):

| Platform | Install dir | Runs as |
|---|---|---|
| Linux, macOS, Termux | `~/.local/lib/cubby/` | the user |
| Windows | `$LOCALAPPDATA/cubby/` under Git Bash | the user |

Installed by `git clone https://github.com/jannoguer/cubby` and `client/install.sh`, updated by `git pull` in that clone. The loop runs `sync` as a child process each iteration, so an updated script takes effect on the next run without a restart; only changes to the loop itself need a service restart. bash reads a script incrementally while it runs, so the loop never sources or re-reads itself.

Subcommands:

| Command | Does |
|---|---|
| `cubby setup DIR --server HOST [--port N] --device NAME [--full]` | Key, host key pinning, clone, per-repo config (5.3), excludes and attributes. |
| `cubby sync DIR` | One pass of 5.4. Exit 0 healthy, 2 unhealthy, 1 could not run. |
| `cubby loop DIR` | 5.6. Foreground, for the service manager. |
| `cubby status DIR` | Prints `.git/cubby/status`. |
| `cubby service install DIR` | Writes the systemd unit, launchd plist, Task Scheduler task or runit service for this platform (5.7). |
| `cubby doctor DIR` | Versions, config drift against 5.3, `git fsck`, lock state, stale `index.lock`. |

Everything device-local lives under `.git/cubby/`: `status`, `state`, `logs/sync.log`, `lock/`, `known_hosts`, `hooks/` (empty). Nothing needs an ignore rule because nothing is inside the work tree. The user's folder contains only the user's files and one `.git` entry.

### 5.2 Clone shape

Default: `git clone --filter=blob:none`. A blobless partial clone holds every commit and tree but fetches file contents only when a checkout needs them.

**Because**:

- Disk on the device is the current tree plus compressed current blobs, not every version ever. A phone or a small laptop carries history metadata only.
- Merge bases are always present. A shallow clone (`--depth`) was rejected because after a long offline period the merge base can fall outside the shallow boundary and `git merge` refuses; deepening on failure is slow and unpredictable.
- The initial download becomes resumable. `git clone` of 50 GB is one non-resumable transfer; a blobless clone downloads metadata in seconds and the following checkout fetches blobs in batches, so a dropped connection loses one batch and `git checkout main` continues.
- Restore of an old version (8.1) fetches just that blob, on demand.

Cost: a checkout or merge that needs blobs needs the server. They happen right after a fetch, so connectivity is already known to be there. `--full` exists for a desktop meant to be a complete second copy.

Android uses `--separate-git-dir "$HOME/.cubby/main.git"`: objects and index on Termux's private ext4, the work tree on shared storage where other apps can see it. The work tree gets a `.git` file pointing at the directory. **Because** `/sdcard` is a FUSE or sdcardfs view with no permission bits, no symlinks, coarse mtimes and slow small-file I/O; the object store there would be slow and fragile, while the work tree there is exactly what the user wants.

### 5.3 Per-repository configuration

All in `.git/config`, written by `setup`, checked by `doctor`. Never global: the user's own git settings stay untouched, and theirs never leak in.

| Key | Value | Because |
|---|---|---|
| `cubby.device` | name given at setup | Identity for commits and conflict copies. Not `hostname`: it changes, and two machines may share one. |
| `cubby.interval` | `60` | Poll period in seconds, section 5.6. |
| `cubby.ntfyUrl` | empty | Section 7. Set per device at setup, so no URL travels through the synced tree and nothing needs to be trusted. |
| `cubby.ntfyWakeUrl` | empty | Section 7.3. |
| `cubby.maxFileSize` | `2147483648` | Same cap as the server hook (4.6), enforced before commit (5.5). |
| `cubby.staleAfter` | `1800` | Seconds without a successful pass before status flips to unhealthy, unless offline (7.1). |
| `user.name` / `user.email` | device / `device@cubby.invalid` | Commits need an identity. `.invalid` is the reserved TLD for exactly this. |
| `commit.gpgsign` | `false` | A global signing setup would prompt or fail unattended. |
| `core.hooksPath` | `.git/cubby/hooks` (empty dir) | A global `core.hooksPath` (husky, lint tooling) must never run against this repo. |
| `core.sshCommand` | `ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -i KEY -o UserKnownHostsFile=KNOWN -o StrictHostKeyChecking=yes -p PORT` | Self-contained: no edits to `~/.ssh/config`, no prompt ever, dead connections die within a minute, host key pinned to the file written at setup. The user's `~/.ssh/config` is still read, so a VPN jump host keeps working. |
| `remote.origin.url` | `cubby@HOST:main.git` | scp-like form, so git sends exactly `git-upload-pack 'main.git'`, which is what the dispatcher whitelists. Port goes through `-p` above. |
| `core.autocrlf` / `core.safecrlf` | `false` | R14. No line-ending conversion, ever. |
| `core.precomposeunicode` | `true` | macOS returns decomposed names from `readdir`; this normalizes to NFC in the index so a name created on Linux and one created on macOS are the same path. |
| `core.quotePath` | `false` | Logs show names as they are. All parsing uses `-z`. |
| `core.longpaths` | `true` (Windows) | Paths past 260 characters do not fail the checkout. |
| `core.bigFileThreshold` | `50m` | Files above it are stored without delta search: `add` and `gc` stay fast and low-memory; disk cost is the same since media does not delta anyway. |
| `core.untrackedCache` / `feature.manyFiles` | `true` | `status` on 100k files in well under a second. |
| `core.fsmonitor` | `true` (macOS, Windows) | git's built-in filesystem monitor makes `status` near-instant; not available on Linux in mainline git. |
| `core.fileMode` | probed by `git init`; forced `false` on Android | R14. Where the filesystem cannot store the bit, never record a change to it. |
| `transfer.fsckObjects` | `true` | Corrupt objects from a bad disk on the server are refused, not copied. |
| `add.ignoreErrors` | `true` | One unreadable file (an exclusively locked PST on Windows) must not abort staging of the other thousand (R13). It is still reported (5.5). |
| `gc.auto` | default | Loose objects get packed at the default threshold; no separate maintenance scheduler is installed. |

`.git/info/attributes`:

```text
* -text -merge
```

**Because** `-text` kills line-ending conversion for every path regardless of any `.gitattributes` the user stores in their folders, and `-merge` makes every both-sides-modified file a conflict instead of a textual three-way merge. Dropbox never merges file contents, and neither should a file sync: a "successful" automatic merge of JSON, CSV, SVG or LaTeX is a silently corrupted file with no conflict marker anyone will see. `info/attributes` has the highest precedence in git, above any in-tree `.gitattributes`, which is the property R12 and R14 need.

`.git/info/exclude`, installed from `client/exclude`:

```text
.DS_Store
._*
.Spotlight-V100
.Trashes
.fseventsd
Thumbs.db
ehthumbs.db
desktop.ini
$RECYCLE.BIN/
.Trash-*/
.thumbnails/
*.swp
*.swo
*~
.~lock.*#
~$*
.#*
*.tmp
*.crdownload
*.part
*.partial
```

OS and editor debris only. `*.conflict-*` is deliberately absent: conflict copies must sync (5.5).

### 5.4 The sync pass

`cubby sync DIR`, one pass, always under the lock (5.8). Steps are numbered because the failure catalogue (11) and the tests (14) refer to them.

1. **Preflight.** `DIR/.git` exists and `git rev-parse --is-inside-work-tree` says yes; otherwise exit 1 with `lastError=not a repository`. `git symbolic-ref -q HEAD` must be `refs/heads/main`; a detached HEAD or another branch (someone ran `git checkout` by hand) is `lastError=HEAD is not main`, exit 2, nothing else happens. **Because** pushing `HEAD:main` from the wrong branch would publish whatever the user was looking at. If `.git/index.lock` exists, is older than ten minutes and no process holds the Cubby lock, remove it and log it: it is the leftover of a crash, and git will otherwise refuse every command forever. If `.git/MERGE_HEAD` exists, a previous pass died mid-merge: run step 6b now, before anything else.
2. **Stage tracked changes.** `git add -u --ignore-errors`. Modifications and deletions of files git already knows.
3. **Stage new files.** `git ls-files -o -z --exclude-from=.git/info/exclude | git add -f --ignore-errors --pathspec-from-file=- --pathspec-file-nul`. **Because** this consults only the device's exclude list. `git add -A` would honour every `.gitignore` inside the user's stored folders, and a stored project's `build/` or `.env` would silently never sync. A file sync syncs files; the user's own git ignore files are content, not policy. Entries ending in `/` in that listing are nested repositories (a folder with its own `.git`); they are skipped and reported (5.5), never added as gitlinks.
4. **Quarantine** (5.5). Unstage and report what cannot sync.
5. **Commit** if `git diff --cached --quiet` says there is something: `git commit -q -m "DEVICE 2026-09-13T10:15:00Z"`.
6. **Fetch and merge.** `git fetch -q origin main`. A connection failure is `state=offline` (7.1), pass ends, exit 2 only if stale. If `origin/main` is not an ancestor of HEAD: `git merge -q --no-edit origin/main`.
   - 6a. Merge succeeds: continue.
   - 6b. Merge fails and `MERGE_HEAD` exists: conflicts. Run the resolver (5.5) and `git commit -q -m "DEVICE conflict"`. If any unmerged entry remains after the resolver, `git merge --abort`, `lastError=unresolvable merge`, exit 2. Nothing is lost: local commits are local, remote commits are remote, and the next pass retries.
   - 6c. Merge fails without `MERGE_HEAD`: git refused to start, almost always "local changes would be overwritten" because a file changed in the milliseconds between step 5 and step 6. Log it, exit 2 quietly (7.1 needs two consecutive errors before notifying); the next pass commits the change first and merges cleanly.
7. **Push** if HEAD is ahead of `origin/main`: `git push -q origin main:main`.
   - Rejected as non-fast-forward: another device pushed between 6 and 7. Go to 6, at most three times per pass.
   - Rejected with `cubby: rejected: file over cubby.maxFileSize` or any other hook message: a manual commit bypassed the quarantine. Squash: `git reset -q --soft origin/main`, then steps 2 to 5 once more (the quarantine now drops the offender), push again. `--soft` keeps index and work tree intact; the only thing discarded is local commit granularity that nobody else has seen. If it fails again, `lastError` is the hook message verbatim, exit 2, notify (7.1).
   - Connection failure: `state=offline`.
8. **Status.** Write `.git/cubby/status` (7.1), append one line to `logs/sync.log`, send transition notifications, release the lock.

Two ssh connections per pass at most, one when nothing changed locally. `ControlMaster` is not used: Git for Windows' ssh does not support it reliably and the handshake is under 200 ms on a LAN.

### 5.5 Quarantine and the conflict resolver

**Quarantine** runs on the staged set after steps 2 and 3 and before the commit. Each rule names the R14 ping-pong or R13 stall it prevents.

| Staged entry | Rule | Action | Because |
|---|---|---|---|
| mode `120000` (symlink) | exclude | `git rm -q --cached -- path` if new, `git reset -q -- path` if it replaced a tracked file | Windows with `core.symlinks false` checks a symlink out as a text file holding the target and commits it back as a regular file; Linux then replaces the link with that file. Neither side ever converges. |
| directory entry from step 3 | exclude | not added | A nested repository would become a gitlink: a 40-hex pointer to a commit nobody else has. Its files never sync and the server rejects it anyway. Report it so the user knows the folder is invisible to Cubby. |
| size over `cubby.maxFileSize` | exclude | as symlink | Non-resumable push, repo growth, and the server would reject the pack. |
| Windows-invalid name (same regex as 4.6) | exclude | as symlink | Windows cannot create the file; that device's checkout would fail at every pass. |
| new path colliding by ASCII case with a tracked path | exclude the new one | as symlink | On a case-insensitive filesystem both names are one file: checkout writes the second over the first, `status` shows the first as modified with the second's content, and the next commit pushes that upstream. That is silent data loss, so the newer name loses. |
| `add` reported an error for it | already unstaged by git | reported | An exclusively locked or unreadable file. It syncs when it can be read. |

Excluded paths are listed in status as `problems=N` with one `problem=path (reason)` line each, and a transition in the set notifies once (7.1). The file stays on disk untouched; Cubby only declines to carry it.

**Conflict resolver.** Input is `git ls-files -u -z`, which lists every unmerged path with its stages: 1 is the common base, 2 is ours (this device), 3 is theirs (the server). Because of `-merge`, git never blended contents; the work tree holds ours and the index holds all stages. Per path:

| Stages present | Meaning | Action | Result |
|---|---|---|---|
| 2 and 3 (with or without 1) | both changed it, or both added it differently | `git show :2:path > CONFLICTNAME`; `git checkout -q --theirs -- path`; `git add -- path CONFLICTNAME` | The server's version keeps the name, so every device converges on one file. This device's version sits beside it under a name that says where and when it came from. |
| 2 only (with or without 1) | they deleted, we modified | `git add -- path` | Modified beats deleted. The file reappears everywhere. |
| 3 only (with or without 1) | we deleted, they modified | `git checkout -q --theirs -- path; git add -- path` | Same rule from the other side. |
| 1 only | both deleted | `git rm -q --cached -- path` | Nothing to keep. |

`CONFLICTNAME` is `STEM.conflict-DEVICE-YYYYMMDDTHHMMSSZ.EXT`: `Report.conflict-laptop-20260913T101500Z.docx`. The extension is preserved so the copy opens with the right application. If the result would exceed 200 bytes the stem is cut; the suffix is unique by device and second, and a second collision within the same second appends `-2`. Rename conflicts fall out of the table: a rename/rename lists the old path with stage 1 only and each new name with one stage, which the rules above keep both of. A directory-versus-file conflict leaves git's `path~HEAD` in the work tree; the following `git add -A` of the resolver's end picks it up rather than losing it, and the status line names it. The copy is taken from stage 2, not the work tree, so a directory or missing file at `path` cannot break it; the cost is that an edit made in the milliseconds between step 5's commit and the merge is superseded by the checkout. That window is measured in milliseconds and the next pass sees the file as modified if anything remained.

**Why the server's version keeps the name and not the local one.** Every device runs the same rule. If local always won, two devices resolving the same conflict would each keep their own under the original name and create a new conflict on the next round. With "theirs wins the name" the merge result is identical on every device and the round ends.

### 5.6 The loop

```text
cubby loop DIR:
    last=0
    producers (optional, each in a subshell, all writing lines into one pipe):
        inotifywait -m -r -q -e close_write,moved_to,moved_from,create,delete,attrib
            --exclude '(^|/)\.git(/|$)' DIR              # Linux, Termux private storage
        fswatch -r --exclude '/\.git(/|$)' DIR           # macOS, if installed
        while :; do curl -sN "$ntfyWakeUrl/raw"; sleep 5; done   # 7.3, if configured
    forever:
        remaining = interval - (now - last); if remaining <= 0: run
        else read -t remaining line from the pipe:
            timeout             -> run
            empty line          -> continue          # ntfy keepalives every ~45 s
            anything else       -> debounce: keep reading with read -t 2 until quiet, then run
    run: "$0" sync DIR; last=now
```

**Because** three triggers (a timer, local file events, a wake from the server) feed one debounced runner. The timer is computed from the last run and not from `read -t` alone; otherwise ntfy keepalives would keep resetting it and the poll would never fire. The two-second quiet period lets an application finish writing a file before it is committed; a partially written file still gets committed if the write takes longer, exactly as Dropbox does, and the next pass carries the rest.

Without `inotifywait` or `fswatch` the loop is the timer alone, at `cubby.interval` (default 60 s). With them, local changes reach the server within about three seconds. Remote changes reach a device at the next timer tick, or within a second with the wake (7.3). `inotifywait -r` on a tree with more directories than `fs.inotify.max_user_watches` fails to start; the loop logs it once and continues on the timer. On Android shared storage inotify does not report writes by other apps, so the phone runs on the timer.

### 5.7 Start at boot

Written by `cubby service install DIR`, one file per platform, all pointing at `cubby loop DIR` with an absolute path:

| Platform | Mechanism | Notes |
|---|---|---|
| Linux | `~/.config/systemd/user/cubby.service`, `Restart=always`, `RestartSec=5` | `loginctl enable-linger` for headless machines, as today. Log: `journalctl --user -u cubby`. |
| macOS | `~/Library/LaunchAgents/io.cubby.sync.plist`, `RunAtLoad`, `KeepAlive` | `launchctl bootstrap gui/$UID`. |
| Windows | `schtasks /Create /SC ONLOGON` running `wscript.exe run-hidden.vbs "C:\Program Files\Git\bin\bash.exe" --noprofile --norc -c "…/cubby loop '/c/Users/me/Cubby'"` | `run-hidden.vbs` is kept unchanged: it exists so Task Scheduler does not flash a console at logon. `--noprofile --norc` so a user's bash profile cannot alter the loop's environment. Git for Windows' `bin/bash.exe` sets `PATH` to its own `git`, `ssh`, `curl` and coreutils. |
| Android | Termux `runit` service under `$PREFIX/var/service/cubby`, `termux-services` and Termux:Boot as today | Nothing about the phone's supervision changes; only the payload is `cubby loop` instead of the Mutagen daemon. |

### 5.8 Lock

`mkdir .git/cubby/lock` is the lock; `mkdir` is atomic on every filesystem in scope, `flock(1)` does not exist on macOS or in Git for Windows. The directory holds a `pid` file. A lock whose pid is not alive (`kill -0`) and whose directory is older than fifteen minutes is stale and is removed with a log line. **Because** a pass killed by a reboot must not block every future pass, and a live pass (a first push of 40 GB) must not be interrupted by the timer.

### 5.9 Android specifics

Kept from today's `client/android/setup.sh`: Termux from F-Droid, `termux-setup-storage`, key generation, host key pinning by fingerprint with `ssh-keyscan`, `termux-services`, Termux:Boot, the phantom-process-killer note. Changed: `pkg install git openssh curl termux-services`, no Mutagen download, no `proot`, no `termux-chroot`. The clone uses the shape in 5.2. After a checkout that added media, the loop runs `termux-media-scan -r DIR` when the command exists, so the gallery sees new files. Photos taken on the phone are the canonical case for section 9, because they are large, immutable, one-directional and want their mtimes; the git tree carries documents.

## 6. Cross-platform rules

R14 in full. Every row is a real ping-pong that has bitten someone using git as a file sync.

| Platform difference | What would ping-pong | Rule that prevents it | Where |
|---|---|---|---|
| Line endings | CRLF on Windows, LF elsewhere | `-text`, `autocrlf false` | 5.3 |
| Executable bit | Windows and Android cannot store it | `core.fileMode` probed by git, forced off on Android; where it is off, git never records a mode change | 5.3 |
| Symlinks | Windows checks out a text file | excluded on the client, rejected on the server | 5.5, 4.6 |
| Case | macOS and Windows collapse `A` and `a` | new colliding path excluded, whole push rejected | 5.5, 4.6 |
| Unicode normalization | macOS `readdir` returns NFD | `core.precomposeunicode true` normalizes to NFC in the index | 5.3 |
| Illegal characters and names | Windows refuses `:`, `?`, trailing dots, `NUL` | excluded and rejected | 5.5, 4.6 |
| Path length | Windows 260 by default | `core.longpaths true`; components over 255 bytes rejected | 5.3, 4.6 |
| Timestamps | git does not record them | nothing to ping-pong; see section 12 for what is lost | |
| Nested repositories | gitlinks nobody can resolve | skipped and reported, rejected | 5.5, 4.6 |
| `.git`-like names | `.GIT`, `git~1`, NTFS streams | `receive.fsckObjects`, and git's own `core.protectNTFS` / `core.protectHFS` defaults | 4.5 |

Portability rules for the script itself, enforced by `shellcheck` and by running the test suite on all three desktop platforms:

- bash 3.2. macOS still ships it. No `mapfile`, no associative arrays, no `${var,,}`. `read -r -d ''` and `read -t` exist in 3.2.
- No `flock`, `timeout`, `readlink -f`, `stat -c`, `sed -i`, `date -d`, `sha256sum`. BSD userland lacks or differs on each. Sizes come from `wc -c <`, ages from epoch seconds stored by the script, paths from `cd && pwd -P`, in-place edits through a temp file and `mv`.
- Every list of paths crosses a pipe as NUL-separated (`-z`, `--pathspec-file-nul`, `read -d ''`). Names with newlines are legal.
- Nothing is ever `eval`ed and no path is ever interpolated into a command string. Paths are arguments or pathspec files.
- `awk` is written for both gawk and BWK awk: no `gensub`, no `length(array)`, no `-v` with escapes.
- Shebang `#!/usr/bin/env bash`: Termux has no `/bin/bash`.

## 7. Health and notifications

### 7.1 Client status

`.git/cubby/status`, written atomically (temp file and `mv`) at the end of every pass:

```text
updatedAt=2026-09-13T10:15:00Z
state=ok                      # ok | offline | error
healthy=true                  # false when state=error, or state=offline for longer than cubby.staleAfter
lastOkAt=2026-09-13T10:15:00Z
head=3f2a9c1
ahead=0
behind=0
conflicts=2                   # tracked paths matching *.conflict-*, i.e. still unresolved by the user
problems=1
problem=Photos/link (symlink)
lastError=
```

Three states, **because** a laptop in a bag is not broken. `offline` is any ssh connection failure; it never notifies on its own and only turns `healthy=false` after `cubby.staleAfter`. `error` is everything else: a hook rejection, an unresolvable merge, a missing repository. `error` notifies after two consecutive passes, not one, because 6c is a legitimate one-pass race.

Notifications go to `cubby.ntfyUrl` with `curl -fsS -m 10 -H "Title: Cubby DEVICE" -d TEXT`, and only on transitions recorded in `.git/cubby/state`:

- `healthy` false to true, and true to false, with `lastError`.
- `conflicts` increased: "2 new conflict copies" with the first two names. A decrease is silent; the user cleaned up and knows.
- The `problem` set changed: added paths listed.
- Push rejected by the server: the hook's message verbatim.

The user resolves a conflict by deleting the copy they do not want, or by renaming the copy over the original. Both are plain file operations in any file manager, exactly like Dropbox's conflicted copies.

### 7.2 Server health

`/usr/local/lib/cubby/health`, from cron every ten minutes, state in `/var/lib/cubby/state`, notifications on transitions only to `NTFY_URL` from `cubby.conf`:

| Check | Threshold | Because |
|---|---|---|
| Free space on the filesystem holding `/srv/cubby` | below `DISK_MIN_FREE_PCT` (default 10) | A full disk fails every push; the clients would report `error`, but the fix is on the server. |
| `git fsck --connectivity-only` | daily, by stamp file | Cheap, catches missing objects. |
| `git fsck` | weekly, by stamp file | Full integrity. A bad disk shows up here before it shows up on a client. |
| Mirror age | if `/var/lib/cubby/mirror-ok` (touched by the mirror host, 8.2) is older than `MIRROR_MAX_AGE` | Pull-based mirrors fail silently by definition; the server has to notice the silence. Optional, only when 8.2 is set up. |
| Last push | none | Quiet is not a failure. Recorded in status output only. |

### 7.3 Fast wake (optional)

`NTFY_WAKE_URL` on the server and `cubby.ntfyWakeUrl` on each device, pointing at one private topic. `post-receive` posts the pushing device's name; every loop holds `curl -sN topic/raw` open and runs a pass on any non-empty line. Remote changes then land in about a second instead of at the next tick. **Because** the server cannot connect to the clients and the clients hold no long-lived ssh session; a public pub-sub channel with a random topic name is the cheapest possible push. The payload is a device name, never a path or content. Anyone who dislikes the timing metadata leaving the LAN leaves both settings empty or self-hosts ntfy; the design does not depend on it.

## 8. History, restore, offsite

### 8.1 Restore

History is the repository (R4). No snapshot tree, no retention tiers, no pruning logic: every version of every file, forever, on the server.

From any device:

```sh
git -C ~/Cubby log --oneline -- 'Reports/Q3.docx'                 # versions of one path
git -C ~/Cubby checkout 3f2a9c1^ -- 'Reports/Q3.docx'              # bring back the version before a commit
git -C ~/Cubby log --diff-filter=D --name-only --oneline           # everything ever deleted, when, by which device
git -C ~/Cubby checkout "$(git -C ~/Cubby rev-list -1 --before='2026-09-12 18:00' main)" -- 'Reports/'   # a folder as it was
```

The next pass commits the restore like any other change and every device receives it. On a blobless clone the old blob is fetched on demand. From the server: `git -C /srv/cubby/main.git show 3f2a9c1:Reports/Q3.docx > /tmp/Q3.docx`. Restore never pauses anything and never needs root; today's `restore.sh`, its symlink checks, its container pause and its staging directory are gone because the operation is a git checkout inside a normal work tree.

### 8.2 Offsite

Pull-based, as today (R8). On another machine with its own key in `/etc/cubby/authorized_keys` under the name `mirror`:

```sh
git clone --mirror cubby@server:main.git /srv/cubby-mirror.git
git -C /srv/cubby-mirror.git config fetch.fsckObjects true
git -C /srv/cubby-mirror.git config core.logAllRefUpdates true
git -C /srv/cubby-mirror.git config gc.reflogExpire never
git -C /srv/cubby-mirror.git config remote.origin.fetch 'refs/heads/*:refs/heads/*'
# cron, hourly:
git -C /srv/cubby-mirror.git fetch -q origin && ssh cubby@server true   # the second call is the liveness stamp, see below
```

**Why the refspec is changed.** `--mirror` sets `+refs/*:refs/*`, and the plus means "force". A compromised or corrupted server publishing a rewritten `main` would then be copied over the good history. Without the plus, a non-fast-forward update is refused and the fetch fails loudly. The server denies non-fast-forwards to clients; the mirror denies them to the server.

**Liveness stamp.** The mirror key's forced command in `shell` gets one extra allowed command, `true`, which the dispatcher turns into `touch /var/lib/cubby/mirror-ok`; `health` reports when the stamp goes stale. The server still holds no credential to the mirror and cannot delete it (R8).

Push-based is possible (`post-receive` running `git push --mirror offsite`) and documented as second choice for the same reason as today: it puts a credential on the server.

### 8.3 Purging

History is permanent by design, so a secret or a 10 GB ISO committed by mistake stays in every clone. The escape is a history rewrite and it is deliberately painful: temporarily unset `receive.denyNonFastForwards`, rewrite with `git filter-repo` or `git filter-branch`, force-push, re-clone every device. It is written down as the procedure and never automated. **Because** anything that could do it from a client is exactly what R5 forbids.

### 8.4 Growth

The server grows by the compressed size of every new version. Text deltas well; media does not delta and is rarely edited, so growth is roughly additions. `git count-objects -vH` reports it and `health` includes it. The client-side cost is in section 12. Target for one repository: 100k files and 100 GB of current content. Beyond that, split into several repositories, which needs one more `case` arm in `shell` and one more `main.git` per tree; nothing else in the design is per-repository.

## 9. Optional: one-way rsync trees

Not built in phase 1. Added only when a folder meets one of these: single files over `cubby.maxFileSize`, mtimes that matter (a photo library), transfers over links so bad that resumability matters, or content so large that history is unwanted.

**Decision.** Such a folder is an rsync target with one writer and any number of readers, jailed per key by `rrsync`, snapshotted on the server with `rsync --link-dest`.

**Because** one-way transfer needs no memory of the last state, so plain rsync is complete and correct here, preserves mtimes, resumes partial files (`--partial`), and is the literal "rsync plus keys" answer wherever the bidirectional requirement does not apply.

The dispatcher grows one arm:

```sh
    "rsync --server"*)
        case "$2" in
            media=rw) exec rrsync /srv/cubby/media ;;
            media=ro) exec rrsync -ro /srv/cubby/media ;;
            *) echo "cubby: this key has no rsync access" >&2; exit 1 ;;
        esac ;;
```

with the key line `restrict,command="/usr/local/lib/cubby/shell phone media=rw"`. The phone runs `rsync -a --partial --no-delete Camera/ cubby@server:Camera/` from the same loop; a desktop reader runs `rsync -a --delete cubby@server:Camera/ Camera/`. Deletions from the writer are the operator's choice per tree: a camera roll is usually append-only so the phone may delete locally and the server keeps everything.

Snapshots, from cron on the server, are what `backup.sh` does today without the container:

```sh
ts=$(date -u +%Y-%m-%dT%H%M%SZ)
rsync -a --delete --link-dest=/srv/cubby/snapshots/latest /srv/cubby/media/ "/srv/cubby/snapshots/.incoming-$ts/" \
    && mv "/srv/cubby/snapshots/.incoming-$ts" "/srv/cubby/snapshots/$ts" \
    && ln -sfn "$ts" /srv/cubby/snapshots/latest
ls -d /srv/cubby/snapshots/????-??-??T??????Z | head -n -"$KEEP" | xargs -r rm -rf
```

Retention is "keep the newest N"; the tiered hourly/daily/weekly scheme is dropped because git history covers the tree that changes often and media trees change by addition. The snapshot directory is never inside `/srv/cubby/media`, so no key reaches it (R5). Offsite: `rsync -aH server:/srv/cubby/snapshots/ snapshots/` from the mirror host, pull-based, hardlinks intact.

## 10. Security model

| Threat | What it can do | What stops the rest |
|---|---|---|
| A device's key is stolen | Read the whole tree and its history. Push deletions and garbage. Push packs up to `receive.maxInputSize` repeatedly. | Cannot rewrite history (`denyNonFastForwards`), cannot delete `main`, cannot reach other repositories, a shell, forwarding or the snapshots. Every push is attributed to the device name in the log. Recovery is one `sed` to revoke and a `git checkout` on any device to undo the content. Disk exhaustion is caught by `health`. |
| The server is compromised | Read everything. Serve rewritten history. | Clients verify objects (`transfer.fsckObjects`). The mirror refuses non-fast-forward refs (8.2) and holds the good history; the server has no credential to it. Encryption at rest is out of scope, as today. |
| A malicious or buggy client pushes hostile content | Filenames, attributes, ignore files, hooks. | Nothing synced is ever executed (R12). `info/attributes` outranks in-tree `.gitattributes`; in-tree `.gitignore` is not consulted (5.4 step 3); hooks are not part of the work tree; `core.hooksPath` is pinned. Paths are only ever arguments or NUL-separated pathspec files. `.git`-like names are refused by fsck on receive. |
| A client fills the tree with case collisions or Windows-illegal names | Break checkout on other platforms. | Excluded on the client, rejected on the server (4.6, 5.5). |
| Network attacker | MITM the first connection. | Host key pinned at setup by fingerprint comparison, as today; `StrictHostKeyChecking=yes` afterwards. |
| Operator mistake on the server | `rm` a ref, bad `gc`. | Reflog kept forever, weekly fsck, mirror. |

What the design does not defend: a device that is compromised while its user is logged in has everything that user has, on every sync tool ever built.

## 11. Failure catalogue

Where each failure is detected, what happens on its own, and what a person must do.

| Failure | Detected by | Automatic | Manual |
|---|---|---|---|
| Server unreachable | fetch or push fails with ssh error (5.4 step 6, 7) | `state=offline`, retry every tick, no notification until `staleAfter` | none |
| Two devices push at once | non-fast-forward rejection (step 7) | fetch, merge, push again, three attempts per pass | none |
| Same file edited on two devices | merge conflict (step 6b) | conflict copy beside the file, notification | pick one, delete the other |
| File deleted here, edited there | stage 3 only (5.5) | edited version restored | none |
| Pass killed mid-merge | `MERGE_HEAD` at preflight (step 1) | resolver runs first, or `merge --abort` | none |
| Pass killed mid-git | stale `index.lock` at preflight | removed after ten minutes when no lock holder | none |
| Loop killed | service manager | restart within five seconds | none |
| Stale Cubby lock after crash | dead pid and age (5.8) | removed | none |
| File changed between commit and merge | merge refuses to start (6c) | next pass | none |
| Symlink, nested repo, huge file, bad name | quarantine (5.5) | excluded, listed in status, notified once | rename, move out, or accept |
| Manual `git commit` of a huge file | hook rejection (step 7) | unpushed commits squashed, offender excluded, pushed | none |
| Manual `git checkout` of a branch or commit | preflight | `error`, nothing pushed | `git checkout main` |
| `.git` deleted by the user | preflight | `error`, notified | `cubby setup` again |
| Server disk full | push fails on the client; `health` on the server | clients `error` after two passes; server notifies once | free space |
| Server repo corruption | weekly `fsck`, `transfer.fsckObjects` on every client fetch | notified; clients refuse bad objects | restore from mirror |
| Mirror stops pulling | stale liveness stamp | notified | fix the mirror host |
| Case-insensitive collision created on Linux | quarantine; server backstop | new name excluded | rename |
| Key revoked while a client is mid-push | push fails | `error` with the ssh message | intended |
| Host key rotated | `StrictHostKeyChecking=yes` fails | `error`, notified with the ssh message | re-pin on each device with `cubby setup --repin` |
| inotify watch limit | `inotifywait` exits at start | timer only, logged once | raise `fs.inotify.max_user_watches` or ignore |
| Android kills Termux | nothing runs | Termux:Boot and battery settings as today | as today |
| Clock wrong on a device | nothing breaks; commit dates and conflict names are cosmetic | none | none |
| Very large first clone interrupted | checkout stops | blobless clone resumes at the next batch (5.2) | rerun `git checkout main`, or seed with `git bundle` over USB |

## 12. What is lost

Plainly, against Mutagen and the current stack.

- **Modification times.** git records none. A checked-out file carries the time of checkout. File managers sorting by date, and anything that trusts mtime, see the sync time. Photos keep their EXIF dates, documents do not keep anything. This is the single largest user-visible regression and the strongest reason section 9 exists for media.
- **Empty directories.** git does not track them. A folder appears on other devices when it holds a file.
- **Symlinks.** Not synced (5.5). Mutagen carried them.
- **Executable bits on Windows and Android.** Unchanged from today; those filesystems never had them.
- **Instant propagation of remote changes.** Mutagen held a session open. Cubby polls at `cubby.interval` unless the ntfy wake is configured (7.3).
- **Resumable transfer of one huge file.** rsync resumes, git restarts the push. Hence the file cap and section 9.
- **Disk on each device.** Work tree plus compressed current blobs: roughly two copies of the current content with a blobless clone, every version ever with `--full`.
- **Permanent history.** A purge means rewriting history and re-cloning every device (8.3).
- **A browsable snapshot tree.** `backups/2026-09-03T030000Z/…` in a file manager becomes `git log` and `git checkout`.
- **SFTP browsing from a phone app.** The server speaks only git. Section 16 has the optional read-only view.
- **Live databases and VM images.** Every save is a new full blob; a 20 GB image edited daily is a repository nobody wants. Dropbox gives the same advice for the same reason.

What is gained, for the record: no Docker, no Mutagen, no PowerShell, no VBS beyond the launcher, no key watcher, no second container, no retention algorithm, no restore script with symlink checks, no marker files travelling through the tree, no trust decision about a URL found in a synced file. Atomic multi-file changes, rename-aware transfer, per-path history on every device, selective sync, offline commits, server-side validation of every path, and a mirror that cannot be overwritten by the thing it mirrors.

## 13. Migration

Cutover, not coexistence. Mutagen and git on the same folder would fight over `.git`.

1. On every device: `mutagen sync flush Cubby`, then `mutagen sync pause Cubby`. Wait until `mutagen sync list` shows no pending changes anywhere.
2. On the server: `docker compose stop`. Do not delete anything. `shared/` is the import source and the rollback.
3. Run `server/install.sh`. Then import, once, from the old tree excluding the marker directory:
   ```sh
   git --git-dir=/srv/cubby/main.git --work-tree=shared add -A -- . ':!.cubby'
   git --git-dir=/srv/cubby/main.git --work-tree=shared commit -q -m "import from Mutagen tree"
   ```
   The pre-receive rules do not run on a local commit, so run the same checks by hand: `server/check-tree main` is `pre-receive` factored to take a ref, and it lists symlinks, bad names and collisions in `shared/` before any client sees them. Fix them in `shared/` and re-import.
4. Add every device's existing `~/.ssh/cubby.pub` to `/etc/cubby/authorized_keys` under its old name. The keys do not change.
5. On each device, without re-downloading: `cubby setup --adopt ~/Cubby`. It runs `git init`, sets the remote and config from 5.3, `git fetch`, `git reset -q origin/main` (mixed: the index becomes the server's tree, the work tree is untouched), then `git status --porcelain -z`. An empty status means the local copy matched the server exactly. A non-empty status lists what differed; the user reads it before the first pass, because the first pass will commit those differences as this device's changes. Files present on the server and missing locally would be committed as deletions, so `--adopt` refuses to continue if any `D` entries appear and prints the list; `git checkout -- path` brings them back, or the user confirms the deletions with `--adopt --accept-deletions`.
6. `cubby service install ~/Cubby`. Remove the Mutagen daemon registration and, on Windows, the `Cubby` login entry `daemon.ps1 -Register` wrote.
7. Watch `cubby status` on every device for a day.
8. After a week: `mutagen sync terminate Cubby` on every device, `docker compose down`, keep `backups/` until its content is older than anything anyone would restore, then delete `shared/`, `config/`, `keys/`, `offsite/`.

Rollback before step 8: `docker compose up -d`, `mutagen sync resume Cubby` on each device. `shared/` still holds the tree as of step 2; changes made through git since then are copied into it from any client's work tree with `rsync -a --exclude .git`, once.

## 14. Tests

`tests/` runs with bash, git and a temp directory; no sshd is needed for most of it because hooks run on pushes to a `file://` remote too. `shellcheck` on every script. CI runs the suite on Ubuntu, macOS (bash 3.2, BSD tools) and Windows (Git Bash).

Server:

- Every 4.6 rule rejects, with the expected message, and a fixed follow-up commit is accepted. Includes the "bad name in an intermediate commit, fixed in the final tree" case and the "huge blob no longer referenced" case.
- `denyNonFastForwards`, `denyDeletes`, other refs refused.
- `shell` with each whitelisted `SSH_ORIGINAL_COMMAND`, with `git-upload-pack '/etc'`, with `git-upload-archive`, with a shell command, with empty. Run directly, no sshd.
- `install.sh` twice on a fresh Debian container: second run changes nothing (`diff -r` of the results).

Client, each as a scenario with two clones of one bare repo:

- Plain change propagates. Deletion propagates. Rename of a large file transfers no blob (measured with `GIT_TRACE_PACKET`).
- Both modify one file: exactly one conflict copy, same final tree in both clones after two passes each, copy content equals the loser's version.
- Modify/delete and delete/modify: the modified version survives.
- Add/add with different content, rename/rename, directory/file.
- Same conflict resolved simultaneously by both clones converges without a second conflict.
- Kill the pass after `merge` starts (inject `exit` after `git merge` via a test hook variable); next pass resolves and the tree is consistent.
- Stale `index.lock` older than ten minutes is removed; a fresh one is respected.
- Stale lock directory with a dead pid is removed; with a live pid the pass exits 1.
- Symlink, nested repo, oversize file, `CON.txt`, `a?b`, trailing dot, case collision: excluded, listed in status, tree still syncs. Server backstop tested by committing the same by hand and pushing.
- Manual commit of an oversize file: hook rejection triggers squash, the second push succeeds, the offender is in `problems`.
- Concurrent pushes: two clones push in a loop for a minute; no pass ends in error, final trees identical.
- Blobless clone: merge with a merge base older than the current checkout succeeds; `checkout` of a historical blob fetches it.
- In-tree `.gitignore` ignoring `build/`: `build/` syncs anyway. In-tree `.gitattributes` with `text=auto`: no CRLF conversion happens on Windows.
- HEAD on another branch: pass exits 2 and pushes nothing.
- `status` file is always complete and never observed half-written (reader loop during passes).
- Notifications: a fake ntfy (`nc -l` or a tiny `python3 -m http.server` in tests only) receives exactly one message per transition, zero for offline under `staleAfter`, zero for a single 6c pass.
- Conflict name: extension preserved, 200-byte truncation, same-second uniqueness.

Integration, in a throwaway container with sshd: setup from scratch on a client, key add, sync, key revoke cuts the next pass, host key rotation is reported as `error` with the ssh text.

## 15. Implementation order

Each milestone leaves a working system for the platforms it covers.

1. **Server.** `install.sh`, `shell`, hooks, `check-tree`, `health`, sshd drop-in, hook tests over `file://`. One evening of work, and the whole R2, R5 story is done.
2. **Client core.** `cubby setup`, `cubby sync` steps 1 to 8 with quarantine and resolver, `status`, logs, Linux only, timer only. The scenario tests in 14.
3. **Loop and services.** `cubby loop` with the three producers, `cubby service install` for Linux, macOS, Windows. CI on the three platforms.
4. **Notifications and health.** 7.1, 7.2, 7.3.
5. **Android.** `client/android/setup.sh` rewritten for git, separate git dir, media scan, runit.
6. **Migration.** `--adopt`, section 13 as a checklist in the README, a dry run on a copy of the real tree.
7. **Mirror.** 8.2 with the liveness stamp.
8. **Optional trees.** Section 9, when a folder needs it and not before.

New repository layout:

```text
server/install.sh          idempotent root installer (4.9)
server/sshd.conf           the Match block (4.3)
server/shell               forced command (4.4)
server/hooks/pre-receive   (4.6)
server/hooks/post-receive  (4.7)
server/check-tree          pre-receive's rules over any ref, for imports (13)
server/health              cron health (7.2)
server/snapshot            section 9, later
server/cubby.conf.example
client/cubby               the one script (5)
client/install.sh          copies cubby into place, checks git and ssh versions
client/exclude             (5.3)
client/attributes          (5.3)
client/run-hidden.vbs      unchanged
client/android/setup.sh    (5.9)
tests/
README.md                  rewritten around the new commands
REDESIGN.md                this file, kept until the README covers everything, then deleted
```

Deleted: `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `authorized-keys.sh`, `on-key-change.sh`, `session.sh`, `backup/`, `client/*.ps1`, `client/linux/mutagen.service`, `.env.example`.

## 16. Deliberately not built

- **A daemon that stays connected.** Sessions that last seconds are what make revocation trivial and the server stateless.
- **Server-side checkout of the tree.** It doubles server disk and adds a second writer to reason about. If browsing on the server matters, `git show` and `git archive` exist. If an SFTP view for a phone app matters, it is a second sshd user with `ChrootDirectory` and `ForceCommand internal-sftp` over a read-only worktree refreshed by `post-receive`; it is documented as an extension, not built, because it reintroduces a path into the tree that is not a git push.
- **Automatic text merging.** Correct for source code, wrong for a file sync (5.3).
- **Tiered retention.** History is complete; there is nothing to tier.
- **A web UI, users, permissions, sharing links, encryption at rest, LFS, a versions browser.** Cubby is one person's files on one person's hardware.
- **Any binary.** If a requirement ever needs one, the answer is git-annex or Syncthing, not a Cubby binary.
