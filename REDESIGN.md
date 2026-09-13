# Cubby redesign: git over ssh

Status: proposal, revision 2. Nothing in this document is implemented. It replaces Mutagen, both containers, the PowerShell clients, the key watcher, the backup sidecar and the notifications with tools that are already on every machine: `sshd`, `git`, `ssh`, `bash`, `cron`. No binary is written or shipped. No network service other than sshd.

Revision 2 folds in the whole design discussion and an independent research pass with primary sources (appendix B). Every claim marked *verified* was reproduced on git 2.47.3 during that work. Every choice states what is done, why, and what it costs.

1. [Requirements](#1-requirements)
2. [The decision](#2-the-decision)
3. [Architecture](#3-architecture)
4. [Server](#4-server)
5. [Client](#5-client)
6. [Cross-platform rules](#6-cross-platform-rules)
7. [Visibility instead of notifications](#7-visibility-instead-of-notifications)
8. [Big files](#8-big-files)
9. [History, restore, mirror, expiry](#9-history-restore-mirror-expiry)
10. [Security model](#10-security-model)
11. [Failure catalogue](#11-failure-catalogue)
12. [What is lost](#12-what-is-lost)
13. [Migration](#13-migration)
14. [Tests](#14-tests)
15. [Implementation order](#15-implementation-order)
16. [Deliberately not built](#16-deliberately-not-built)
- [Appendix A: verified and unverified claims](#appendix-a-verified-and-unverified-claims)
- [Appendix B: sources](#appendix-b-sources)

## 1. Requirements

| # | Requirement | Today |
|---|---|---|
| R1 | One tree, many devices, changes flow in every direction, offline edits merge later. | Mutagen |
| R2 | Key-only ssh. One key per device. Add and revoke without restarting anything. | sshd + AuthorizedKeysCommand + inotifyd killer |
| R3 | Deletions propagate. A conflict never discards data. Conflicts are visible in the folder, Dropbox style. | Mutagen |
| R4 | Every past version is kept and can be restored per path from any device. | rsync hardlink snapshots |
| R5 | No client key can alter or destroy the history. | second container, separate volume |
| R6 | Health is visible on each device without logging in anywhere. No push notifications. | status markers + ntfy |
| R7 | Offsite copy, opt-in, pull-based, the server holds no credentials. | rsync -aH |
| R8 | Linux, macOS, Windows, Android clients. Start at boot. | pwsh, systemd, runit |
| R9 | Install is a clone and one script per side. | yes |
| R10 | Only widely used tools. Nothing compiled by this project. | violated by Mutagen |
| R11 | Local changes sync within seconds, remote changes arrive within seconds. | Mutagen session |
| R12 | Big files work with no size cap. Multi-gigabyte files are ordinary files. | Mutagen |
| R13 | Nothing that is synced is ever executed. | `.cubby/client` had to be root-owned |
| R14 | A file that cannot exist on one platform never stalls the sync of every other file. | |
| R15 | No state that differs between platforms is ever recorded in the sync. | |
| R16 | Simple. One script per side. Every feature earns its lines. | |

## 2. The decision

### 2.1 Why not rsync alone

Bidirectional sync needs a transfer, a conflict detector, and a memory of what the tree looked like after the last successful sync. Without the memory, "deleted here" and "created there" are indistinguishable. rsync has only the transfer. Building the memory in shell is Unison reimplemented badly, with the tree changing underneath.

### 2.2 Why git

git is the memory (index and HEAD), the transfer (pack protocol over ssh), the conflict detector (three-way merge against a shared base) and the history (R4), in one tool installed on every device including Termux and Git for Windows. It adds atomic multi-file changes, rename-aware transfer, offline commits, per-path restore from any device, selective sync, and a server that cannot lose history when told so by two config lines (R5).

**Decision.** The synced folder is a git working tree. The server is a bare repository behind sshd. Every device commits its changes, fetches, merges under a never-blend-contents rule that keeps both versions on conflict, and pushes. git does the merge. Our code decides only what to stage, how to name a loser, and when to stop.

### 2.3 Rejected along the way

| Alternative | Rejected because |
|---|---|
| Syncthing, Mutagen, Unison, git-annex, git-lfs | Binaries, daemons or protocols of their own. R10. |
| A Go program | Out of scope by the owner. |
| Server-side merging with per-device branches | Replaces git's merge with our code on the critical path, and a client that overwrites its work tree on a stamp check is the kind of cleverness that fails once. |
| Applying remote state with `git checkout` and reconciling afterwards | `git checkout` exits 0 after failing to overwrite a locked file, moves HEAD anyway, and the next `add -u` would commit the stale content and revert the other device's edit. *Verified.* Section 5.5. |
| rsync one-way trees for media | Unneeded once big files have no cap. One mechanism. |
| Symlinks as text placeholders on Windows | Ten lines and an unverified git behaviour for a feature nobody uses in a documents folder. Symlinks are excluded. |
| ntfy notifications | The owner wants the Dropbox feel: what needs attention is visible in the folder. Section 7. |
| A file size cap | The reasons for it either do not exist (git streams big files when told to) or are better answered by settings (section 8). |
| Containers | The server is a user, a directory, an sshd drop-in, one dispatcher, one hook and two cron lines. |

## 3. Architecture

```text
 laptop                        server (Debian, no containers)              desktop
 ------                        ------------------------------              -------
 ~/Cubby/        work tree     sshd :22, Match User cubby, ForceCommand    ~/Cubby/
 ~/Cubby/.git    pointer file  /etc/cubby/authorized_keys   root-owned     ~/.cubby/main.git
 ~/.cubby/main.git             /usr/local/lib/cubby/shell   dispatcher
   info/exclude                /srv/cubby/main.git          bare
   info/attributes               denyNonFastForwards, denyDeletes
   cubby/status, logs, lock      hooks/pre-receive (root-owned)
                               cron: maintenance, fsck, disk -> cron mail
 cubby loop  <--ssh-->                                        <--ssh-->  cubby loop
   watcher + long-poll wait                                              fsmonitor poll + wait
                                        |
 phone (Termux)                         | pull-based, read-only key
 ~/storage/shared/Cubby                 v
 ~/.cubby/main.git             mirror host: git clone --mirror, cron fetch, fsck
```

## 4. Server

### 4.1 Packages and versions

Debian stable: `openssh-server`, `git`, `cron`. Nothing else.

| Tool | Minimum | Because |
|---|---|---|
| OpenSSH | 7.6 | `restrict` (7.2), `ExposeAuthInfo` (7.6). |
| git | 2.30 | Stable partial clone, `init -b`. Debian 11 ships 2.30, Debian 13 ships 2.47. |

### 4.2 Layout

```text
/etc/cubby/authorized_keys      root:root 0644. One line per device: restrict <key> <name>.
/etc/cubby/devices              root:root 0644. "<name> rw|ro". Absent name means rw.
/usr/local/lib/cubby/shell      root:root 0755. ForceCommand for the cubby user.
/usr/local/lib/cubby/hooks/     root:root 0755. pre-receive. Set as core.hooksPath.
/usr/local/lib/cubby/health     root:root 0755. Cron: disk, staleness. Output only when wrong, so cron mails only then.
/srv/cubby/                     cubby:cubby 0755. Home of the cubby user; 'main.git' resolves against it.
/srv/cubby/main.git/            cubby:cubby. The bare repository.
/srv/cubby/main.git/config      root:root 0644. git never writes it; a push cannot change policy.
/var/lib/cubby/seen/<name>      cubby:cubby. Touched by the dispatcher at every connection.
/var/lib/cubby/pushed/<name>    cubby:cubby. Touched by post-receive.
```

**Why root owns config and hooks.** `git-receive-pack` runs as `cubby` and writes objects and refs, never `config` or hooks. Owning those as root means a client, which can only ever run `git-receive-pack`, cannot turn off `denyNonFastForwards` even through an unknown git bug that let it write inside the repo. `core.hooksPath` points outside the repository so a hook cannot be planted through the object store either.

### 4.3 sshd

`/etc/ssh/sshd_config.d/10-cubby.conf`:

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
    ExposeAuthInfo yes
    ForceCommand /usr/local/lib/cubby/shell
    ClientAliveInterval 30
    ClientAliveCountMax 3
    MaxSessions 4
    MaxAuthTries 3
    LogLevel VERBOSE
Match all
```

Every keyword is on the list sshd allows inside `Match` (appendix B, S19). `PermitUserEnvironment` is not, which is why the device name does not travel through `environment=`.

**Why `Match all` at the end.** Debian's `sshd_config` includes `sshd_config.d/*.conf` on its first line. A `Match` block stays open until the next `Match`, so without the reset every global directive in the main file would be parsed inside `Match User cubby` and sshd would refuse to start. `Match all` closes the block. Check with `sshd -T -C user=cubby`.

**Why `ForceCommand` and `ExposeAuthInfo` rather than `command=` per key.** `ForceCommand` supersedes any `command=` in `authorized_keys` (S18), so it is the outer wall: a malformed or hand-edited key line can never yield a shell. `ExposeAuthInfo` writes the key that authenticated into the file named by `SSH_USER_AUTH`; the dispatcher maps it to the device name through the comment field of the same root-owned file. The name a client is logged under is therefore never something the client supplied.

**Why the host sshd on port 22.** One daemon, one host key, one firewall rule that `ufw` actually enforces. The `Match` block cannot loosen anything for other users.

The user: `useradd --system --home-dir /srv/cubby --shell /bin/sh cubby`. The shell must be a real shell because sshd runs `ForceCommand` as `$SHELL -c`. The dispatcher is the restriction, not the shell.

### 4.4 Keys and the dispatcher

`/etc/cubby/authorized_keys`, one line per device:

```text
restrict ssh-ed25519 AAAA... laptop
restrict ssh-ed25519 AAAA... phone
restrict ssh-ed25519 AAAA... mirror
```

`restrict` disables pty, forwarding, X11, agent and `~/.ssh/rc`, and "includes all restrictions added in the future". Names: `[A-Za-z0-9._-]+`. `/etc/cubby/devices` holds `mirror ro`.

Add a device: append a line. Revoke: delete it. Neither restarts anything; sshd reads the file at each authentication. A session already open ends on its own, bounded by the fifty-five second `wait` cap. `pkill -u cubby` exists for the impatient.

`/usr/local/lib/cubby/shell`:

```sh
#!/bin/sh
# ForceCommand for the cubby user. Names the device from the key that authenticated,
# allows exactly the git transport for main.git plus a long-poll, refuses everything else.
set -u
repo=/srv/cubby/main.git
key=$(awk '$1 == "publickey" { print $2 " " $3; exit }' "$SSH_USER_AUTH")
name=$(awk -v k="$key" '{ for (i = 1; i < NF; i++) if ($i " " $(i+1) == k) { print $(i+2); exit } }' /etc/cubby/authorized_keys)
[ -n "$name" ] || exit 1
role=$(awk -v n="$name" '$1 == n { print $2 }' /etc/cubby/devices)
export CUBBY_DEVICE=$name
touch "/var/lib/cubby/seen/$name"
case "${SSH_ORIGINAL_COMMAND-}" in
    "git-upload-pack 'main.git'" | "git upload-pack 'main.git'")
        exec git-shell -c "git-upload-pack 'main.git'" ;;
    "git-receive-pack 'main.git'" | "git receive-pack 'main.git'")
        [ "${role:-rw}" = rw ] || exit 1
        exec git-shell -c "git-receive-pack 'main.git'" ;;
    wait\ *)
        sha=${SSH_ORIGINAL_COMMAND#wait }
        case "$sha" in *[!0-9a-f]* | '') exit 1 ;; esac
        i=0
        while [ "$i" -lt 55 ]; do
            cur=$(git -C "$repo" rev-parse -q --verify refs/heads/main)
            if [ "$cur" != "$sha" ]; then echo "$cur"; exit 0; fi
            sleep 1; i=$((i + 1))
        done
        echo "$sha" ;;
    *)
        logger -t cubby "refused $name: ${SSH_ORIGINAL_COMMAND-}"
        exit 1 ;;
esac
```

**Why a dispatcher and not `git-shell` as the login shell.** `git-shell` accepts any repository path the user can read. The dispatcher pins the exact strings git sends, refuses `git-upload-archive`, enforces the read-only role for the mirror, and provides `wait`, which is how a device learns that `main` moved without polling (5.6). No `eval`, no interpolation of client input into a command.

### 4.5 The repository

```sh
git init -q --bare -b main /srv/cubby/main.git
cd /srv/cubby/main.git
git config receive.denyNonFastForwards true   # R5: history is append-only for every client
git config receive.denyDeletes true           # R5: main cannot be deleted
git config receive.fsckObjects true           # malformed objects refused at the door
git config receive.fsck.hasDotgit error       # .git, .GIT, git~1 as path components: error, not warning
git config receive.fsck.largePathname error
git config receive.autogc false               # gc only from cron (4.7); a push never triggers a 100 GB repack
git config uploadpack.allowFilter true        # clients clone --filter=blob:none (5.2)
git config core.hooksPath /usr/local/lib/cubby/hooks
git config core.bigFileThreshold 64m          # above this: no delta search, streamed, stored whole (8.1)
git config gc.bigPackThreshold 1g             # packs this large are kept, not rewritten by gc
git config gc.cruftPacks true
git config gc.pruneExpire 2.weeks.ago
git config core.logAllRefUpdates true         # bare repos default to no reflog; keep one
git config gc.reflogExpire never
git config gc.reflogExpireUnreachable never
git config core.fsync committed
git config user.name cubby
git config user.email cubby@localhost
tree=$(git hash-object -t tree /dev/null)
git update-ref refs/heads/main "$(git commit-tree "$tree" -m init)"
chown root:root config
```

`receive.maxInputSize` is deliberately unset (R12).

**Why an initial commit.** A clone of an empty repository has no `main`; one empty commit removes a special first-push path from the client.

### 4.6 pre-receive

Two jobs: only `main` exists, and the final tree contains nothing that breaks another platform (R14, R15). The client already refuses these before commit (5.5); the hook is the backstop against a hand-run `git push` or a hostile key. It runs in under a second for ordinary pushes.

```sh
#!/bin/sh
set -u
zero=0000000000000000000000000000000000000000
fail() { echo "cubby: rejected: $1" >&2; exit 1; }
while read -r old new ref; do
    [ "$ref" = refs/heads/main ] || fail "only main is synced, not $ref"
    [ "$new" != "$zero" ] || fail "main cannot be deleted"
    # Modes: only regular files. Symlinks (120000) and nested repositories (160000) never converge.
    git ls-tree -r -z "$new" | tr '\0' '\n' | awk '$1 != "100644" && $1 != "100755" { print; bad = 1 } END { exit bad }' >&2 \
        || fail "symlink or nested repository in the tree"
    # Names Windows cannot create, components over 255 bytes, the attention file at any depth.
    git ls-tree -r --name-only -z "$new" | tr '\0' '\n' | awk '
        { n = split($0, c, "/")
          for (i = 1; i <= n; i++) {
              if (c[i] ~ /[<>:"|?*\\]/ || c[i] ~ /[\001-\037]/ || c[i] ~ /[. ]$/ || length(c[i]) > 255 ||
                  toupper(c[i]) ~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$/ ||
                  toupper(c[i]) == "CUBBY-ATTENTION.TXT") { print; bad = 1; break } } }
        END { exit bad }' >&2 || fail "path invalid on Windows or reserved"
    dups=$(git ls-tree -r --name-only -z "$new" | tr '\0' '\n' | tr 'A-Z' 'a-z' | sort | uniq -d)
    [ -z "$dups" ] || fail "paths differ only by case: $dups"
    # Mass deletion: a second line behind the client guard (5.4 step 4).
    if [ "$old" != "$zero" ]; then
        del=$(git diff-tree -r --no-renames --diff-filter=D --name-only -z "$old" "$new" | tr -cd '\0' | wc -c)
        total=$(git ls-tree -r --name-only -z "$old" | tr -cd '\0' | wc -c)
        if [ "$del" -gt 1000 ] && [ "$((del * 4))" -gt "$total" ] \
           && ! git log --format=%B "$old..$new" | grep -qx 'Cubby-Confirm-Delete: yes'; then
            fail "$del deletions in one push; confirm on the device with cubby accept-deletions"
        fi
    fi
done
```

**Why the final tree, not every commit.** A bad name fixed in a later local commit must not block forever. Case collisions are checked ASCII-only on purpose: Unicode case folding differs between macOS and Windows and no shell tool agrees with either.

### 4.7 Cron

```text
*/10 * * * *  root   /usr/local/lib/cubby/health
0 3 * * *     cubby  git -C /srv/cubby/main.git maintenance run --task=incremental-repack --task=commit-graph
0 4 * * 0     cubby  git -C /srv/cubby/main.git gc --quiet --cruft && git -C /srv/cubby/main.git fsck --connectivity-only --no-dangling
0 5 1 * *     cubby  git -C /srv/cubby/main.git fsck --no-dangling
```

`health` prints only when something is wrong: filesystem over 85 percent, a device not seen for more than the configured days. cron mails root on output, as it always has. That is the whole server alerting story (R6). `cubby status` on the server prints per-device last seen and last push from `/var/lib/cubby`.

### 4.8 Install

`server/install.sh`, idempotent, root, from a clone of this repository: packages, user, directories, dispatcher, hooks, repository config re-applied on every run, sshd drop-in tested with `sshd -t` before reload, host key fingerprint printed. Key management is documented one-liners:

```sh
printf 'restrict %s %s\n' "$(cut -d' ' -f1-2 laptop.pub)" laptop >> /etc/cubby/authorized_keys   # add
sed -i '/ laptop$/d' /etc/cubby/authorized_keys                                               # revoke
ssh-keygen -lf /etc/cubby/authorized_keys                                                     # list, also validates
```

## 5. Client

### 5.1 Layout

One bash script, `client/cubby`, installed outside the synced tree (R13) at `~/.local/lib/cubby/` (Linux, macOS, Termux) or `$LOCALAPPDATA/cubby/` (Windows, Git Bash). Installed by cloning this repository and running `client/install.sh`; updated by `git pull` there. The loop runs `sync` as a child process, so an updated script applies at the next pass.

| Command | Does |
|---|---|
| `cubby setup DIR --server HOST [--port N] --device NAME [--adopt] [--full]` | Key, host key pinned by fingerprint, clone, per-repo config, excludes, attributes, service. |
| `cubby sync DIR` | One pass (5.4). Exit 0 healthy, 2 attention needed, 1 could not run. |
| `cubby loop DIR` | 5.6. Foreground, for the service manager. |
| `cubby status DIR` | Prints the status file. |
| `cubby accept-deletions DIR` | Releases a held mass deletion (5.4 step 4). |
| `cubby service install DIR` | Writes the boot entry for this platform (5.7). |

Restore, history and conflict handling are plain git commands documented in the README (9.1), because the repository is a normal one.

Device-local state lives under `~/.cubby/main.git/cubby/`: `status`, `logs/sync.log`, `lock/`, `known_hosts`, `hooks/` (empty). The folder itself holds only the user's files, a one-line `.git` pointer file, and `CUBBY-ATTENTION.txt` while something needs attention (section 7).

### 5.2 Clone shape

```sh
git clone --filter=blob:none --separate-git-dir "$HOME/.cubby/main.git" cubby@HOST:main.git ~/Cubby
```

**`--separate-git-dir`.** The object store is outside the folder. Spotlight, photo apps and backup tools never crawl `.git/objects`; the watcher has nothing to exclude; if the drive holding the folder is unmounted, the pointer file is gone and every pass stops with "not a repository" instead of seeing an empty tree. Android needs this anyway (5.9). Plain git still works inside the folder through the pointer.

**`--filter=blob:none`.** A blobless partial clone holds every commit and tree but fetches file contents only when a checkout needs them. Disk on the device is the current tree plus its compressed blobs, not every version. Merge bases are always present, which a shallow clone cannot promise after a long offline period. The initial download is resumable: metadata in seconds, then blobs in batches, and a dropped connection loses one batch. Old-version restore fetches one blob on demand. Cost: a merge that needs blobs needs the server, which is the moment right after a fetch. `--full` for a desktop meant as a complete second copy.

### 5.3 Per-repository configuration

All in the repository's `config`, written by `setup`, never global.

| Key | Value | Because |
|---|---|---|
| `cubby.device` | name from setup | Identity for commits and conflict copies. Not `hostname`: it changes, and two machines may share one. |
| `cubby.interval` | `60` | Full-pass timer (5.6). |
| `cubby.settle` / `cubby.settleBig` | `2` / `15` | Seconds a file must be unchanged before it is staged (5.4 step 2). |
| `user.name` / `user.email` | device / `device@cubby.invalid` | Commits need an identity; `.invalid` is reserved for exactly this. |
| `commit.gpgsign` | `false` | A global signing setup would prompt or fail unattended. |
| `core.hooksPath` | `cubby/hooks` (empty) | A global `core.hooksPath` must never run against this repo. |
| `core.sshCommand` | `ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -i KEY -o UserKnownHostsFile=KNOWN -o StrictHostKeyChecking=yes -p PORT` | No prompt ever, dead connections die within a minute, host key pinned to the file written at setup, `~/.ssh/config` still honoured for jump hosts. |
| `remote.origin.url` | `cubby@HOST:main.git` | scp-like form so git sends exactly `git-upload-pack 'main.git'`. |
| `core.autocrlf` / `core.safecrlf` | `false` | R15, and streaming (8.1). |
| `core.symlinks` | `false` | Symlinks are excluded anyway; never create one from a hostile tree. |
| `core.protectNTFS` / `core.protectHFS` | `true` | Each defaults on only on its own OS. `.git` look-alikes refused everywhere. |
| `core.precomposeunicode` | `true` | macOS returns decomposed names; normalize to NFC in the index. |
| `core.longpaths` | `true` (Windows) | Paths past 260 characters check out. |
| `core.quotePath` | `false` | Logs show names as they are. All parsing uses `-z`. |
| `core.bigFileThreshold` | `64m` | Above it: no delta search, streamed in and out, stored whole (8.1). |
| `core.untrackedCache` / `feature.manyFiles` / `index.threads` | `true` | `status` on 100k files in well under a second. |
| `core.fsmonitor` | `true` where available | git's built-in watcher: macOS and Windows since 2.37, Linux since 2.55 (S11). Falls back silently where absent. |
| `core.fileMode` | probed by clone; `false` on Android | R15. Where the filesystem cannot store the bit, never record a change to it. |
| `merge.renames` / `diff.renames` | `false` | A rename here and an edit there yields both files rather than a rename conflict. Deterministic, and faster on large trees. |
| `transfer.fsckObjects` | `true` | Corrupt objects from a bad server disk are refused, not copied. |
| `push.default` | `nothing` | Pushes are always explicit `main:main`. |

`info/attributes`:

```text
* -text -diff -merge -filter -ident -working-tree-encoding
```

This line is load-bearing twice. `-merge` makes every both-sides-edited file a conflict instead of a textual three-way merge: a file sync that "successfully" merges JSON or a document is a silently corrupted file. `-text` and the rest prove to git that no content conversion can ever apply, and only then does git stream files above `core.bigFileThreshold` straight into packs instead of reading them whole into memory. *Verified:* without this line a file above the threshold became a loose object; with it, a pack. Git for Windows installs `autocrlf=true` by default, so without it a 20 GB add would try to allocate 20 GB. `info/attributes` has the highest precedence in git, above any `.gitattributes` a user stores in their folders.

`info/exclude`:

```text
/CUBBY-ATTENTION.txt
/.cubby-attention.tmp
.DS_Store
._*
.Spotlight-V100
.Trashes
.fseventsd
.TemporaryItems
Thumbs.db
ehthumbs.db
desktop.ini
$RECYCLE.BIN/
System Volume Information/
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

OS and editor debris only. Conflict copies are deliberately absent: they must sync.

### 5.4 The sync pass

One pass, under the lock (5.8). Numbered so the failure catalogue (11) and the tests (14) can refer to steps.

1. **Preflight.** The pointer file and repository exist, else exit 1 with "not a repository". `git symbolic-ref -q HEAD` is `refs/heads/main`, else attention "HEAD is not main" and nothing else happens: pushing from another branch would publish whatever the user was looking at. If `MERGE_HEAD` exists a previous pass died mid-merge: run step 7b now. If `index.lock` exists, remove it only when it is older than an hour and no git process is alive; a 20 GB `add` on a phone holds it legitimately for a long time.
2. **Collect candidates.** Modified and deleted tracked files from `git diff-files -z --name-only`. New files from `git ls-files -o -z --exclude-from=GITDIR/info/exclude`, which consults only the device's list: a stored project's own `.gitignore` is content, not policy, so its `build/` syncs like everything else. Drop any candidate whose mtime is within `cubby.settle` seconds of now, or within `cubby.settleBig` seconds for files over 64 MiB, so a file still being written waits one pass. A future mtime counts as settled.
3. **Quarantine** (5.5). Drop, and record, what cannot travel.
4. **Mass-deletion guard.** If deletions among the candidates exceed both 100 files and a fifth of the tracked tree, hold the deletions, write the attention entry, and keep syncing everything else. `cubby accept-deletions` releases them and adds the trailer `Cubby-Confirm-Delete: yes` to that commit for the server's second line. An unmounted drive is caught earlier by the pointer file; this catches a mistaken `rm -r` or an application emptying a folder.
5. **Stage.** Modified and deleted through `git add -u --pathspec-from-file=- --pathspec-file-nul`, new through `git add -f --ignore-errors --pathspec-from-file=- --pathspec-file-nul`. An unreadable or exclusively locked file fails alone and is reported; the rest stages.
6. **Commit** if `git diff --cached --quiet` says there is something: `git commit -q -m "DEVICE" --date="@NEWEST_MTIME"`. The author date is the newest mtime among the staged files, read with `date -r`, which is what 5.4 step 8 restores on other devices. Files over 256 MiB are committed and pushed one per commit before the rest, so an interrupted push loses one file, not the batch.
7. **Fetch and merge.** `git fetch -q origin main`. A connection failure is `offline`, pass ends. If `origin/main` is not an ancestor of HEAD:
   - 7a. **Writability probe.** For every path in `git diff --name-only -z HEAD origin/main`, open it read-write without truncating (`exec 3<>path`). A path that cannot be opened, typically a document held by an application on Windows, is listed in the attention file as "waiting on" and the merge is skipped this pass. Nothing changes.
   - 7b. `git merge -q --no-edit origin/main`. Success: continue. Failure with `MERGE_HEAD` present: conflicts; run the resolver (5.5) and `git commit -q -m "DEVICE conflict"`. Any unmerged entry left: `git merge --abort`, attention "unresolvable merge", nothing lost, next pass retries. Failure without `MERGE_HEAD`: git refused to start, almost always a file changed in the milliseconds since step 6; next pass commits it first.
   - Why plain `git merge` and nothing else. *Verified:* a real three-way merge that cannot write a file exits 2 and changes nothing. A fast-forward that cannot write a file leaves HEAD alone and partially writes other files with the remote content, which is harmless: the next pass commits identical blobs and merges trivially. `git checkout` and `git reset --keep` are never used to apply remote state (2.3). `--no-ff` is not used because every device would push an empty merge commit on every fetch, forever.
8. **Restore mtimes.** For the commits that arrived, one `git log -z --format=%x00%at --name-only --reverse OLD..HEAD` pass, then `touch` each changed file to its commit's author date. Single-file saves come back exact; a batch is off by the settle window. `git update-index --refresh` afterwards so the touched files are not rehashed on every pass.
9. **Push** if HEAD is ahead: `git push -q origin main:main`. Non-fast-forward rejection: another device won the race, back to 7, at most five times. `cubby: rejected:` from the hook: a hand-made commit bypassed the quarantine; quarantine the named path, commit the fix, push once more; then attention with the message verbatim. Connection failure: `offline`.
10. **Status.** Write `cubby/status`, rewrite or remove `CUBBY-ATTENTION.txt` (section 7), append one line to the log, release the lock.

One ssh connection when nothing changed locally, two otherwise, plus the standing `wait` (5.6).

### 5.5 Quarantine and the conflict resolver

**Quarantine** runs on the candidate list before anything is staged, so nothing unwanted ever enters the index.

| Candidate | Action | Because |
|---|---|---|
| symlink | drop, report | Windows checks out a text file and commits a regular file back; Linux replaces the link. Never converges. |
| directory entry from `ls-files -o` (a nested repository) | drop, report | Would become a gitlink to a commit nobody has; its files invisible to Cubby. The user should know. |
| FIFO, socket, device | drop, report | git cannot store them. |
| name invalid on Windows: `<>:"|?*\`, control characters, trailing space or dot, `CON PRN AUX NUL COM1-9 LPT1-9` with any extension, component over 255 bytes | drop, report | That device's checkout would fail at every pass. |
| new path colliding by ASCII case with a tracked path | drop the new one, report | On a case-insensitive filesystem both names are one file: the second checkout overwrites the first and the next commit pushes that upstream. Silent loss. |
| `.git` look-alike component | drop, report | fsck would reject it anyway. |
| `CUBBY-ATTENTION.txt`, `.cubby-attention.tmp` | drop | Device-local by definition (section 7). |
| `add` reported an error | already unstaged by git, report | Unreadable or locked. Syncs when it can be read. |

**Conflict resolver.** Input is `git ls-files -u -z`: every unmerged path with its stages, 1 base, 2 ours, 3 theirs. Because of `-merge` git never blended anything; the work tree holds ours and the index holds every stage.

| Stages | Meaning | Action | Result |
|---|---|---|---|
| 2 and 3, with or without 1 | both changed it, or both added it differently | `git show :2:path > COPY`; `git checkout -q --theirs -- path`; `git add -- path COPY` | The server's version keeps the name. This device's version sits beside it. |
| 2 only, with or without 1 | they deleted, we modified | `git add -- path` | Modification beats deletion. |
| 3 only, with or without 1 | we deleted, they modified | `git checkout -q --theirs -- path; git add -- path` | Same rule, other side. |
| 1 only | both deleted | `git rm -q --cached -- path` | Nothing to keep. |

`COPY` is Dropbox's name: `Report (conflicted copy laptop 2026-09-13 101500).docx`. Extension preserved so it opens with the right application; the device is the one whose version lost; the time is the local commit's. Over 200 bytes the stem is cut; a same-second twin gets `-2`. With `merge.renames false` there are no rename cases: a rename on one side and an edit on the other yields the renamed file and the edited original, both present. A directory-versus-file conflict leaves git's `path~HEAD`; the resolver's closing `git add -A` keeps it and the attention file names it. The copy is taken from stage 2, not the work tree, so a directory or missing file at `path` cannot break it.

**Why the server's version keeps the name.** `main` is the only thing any device ever merges with, so "theirs" means the same thing on every device and the result tree is identical everywhere. Two devices that both had unpushed edits to the same file each produce their own copy under their own name; the second one to push merges a tree that differs only by a new copy, and the round ends. This is also Dropbox's rule: the second save becomes the conflicted copy.

### 5.6 The loop

```text
cubby loop DIR:
    last_full = 0
    producers, each in a subshell, all writing lines into one pipe:
        Linux:            inotifywait -m -r -q -e close_write,moved_to,moved_from,create,delete,attrib DIR
        macOS, Windows:   every 3 s: git status --porcelain -z | head -c1     (fsmonitor makes this ~free)
        Android:          every 10 s: same                                    (inotify blind on shared storage)
        all:              loop: ssh cubby wait $(git rev-parse origin/main); print; sleep 5..300 on failure
    forever:
        remaining = interval - (now - last_full)
        read -t remaining line:
            timeout            -> full pass
            line               -> debounce with read -t 2 until quiet, then pass
    every 10 min a full pass regardless: inotify queue overflow and watch limits are silent
```

Local changes reach the server within about three seconds where a watcher exists. Remote changes reach a device within a second through `wait`, which is one idle ssh session per device that returns the moment `main` moves. Both are optional: the timer alone is a correct, slower Cubby. `inotifywait` that fails to start (watch limit) is logged once and the timer carries on.

### 5.7 Start at boot

| Platform | Mechanism | Notes |
|---|---|---|
| Linux | `~/.config/systemd/user/cubby.service`, `Restart=always`, `RestartSec=5` | `loginctl enable-linger` for headless machines. Log: `journalctl --user -u cubby`. |
| macOS | `~/Library/LaunchAgents/io.cubby.sync.plist`, `RunAtLoad`, `KeepAlive` | `launchctl bootstrap gui/$UID`. |
| Windows | `schtasks /Create /SC ONLOGON /RL LIMITED /NP /RU USER /TR "bash.exe --noprofile --norc -c '...cubby loop DIR'"` | `/NP` runs without a stored password, non-interactively, so no console window. It needs the "Log on as a batch job" right, which standard users lack by default, and a local account. Where that fails, the fallback is the interactive task through `run-hidden.vbs`, twenty lines that need no PowerShell. Git for Windows' `bin/bash.exe` sets `PATH` to its own git, ssh and coreutils. |
| Android | Termux `runit` service, `termux-services`, Termux:Boot, `termux-wake-lock` | As today, with `cubby loop` as the payload. The phantom process killer still has to be disabled once. |

### 5.8 Lock

`mkdir cubby/lock` is the lock: atomic on every filesystem in scope, while `flock(1)` does not exist on macOS or in Git Bash. It holds a `pid` file. Stale means the pid is dead and no git process is alive and the directory is older than an hour. A first push of 40 GB must never be interrupted by the timer; a reboot must never block every future pass.

### 5.9 Android

Kept from today's installer: Termux from F-Droid, `termux-setup-storage`, key generation, host key pinned by fingerprint, `termux-services`, Termux:Boot, the phantom-process-killer note. Changed: `pkg install git openssh termux-services`, no Mutagen, no `proot`. The clone is 5.2 with the work tree on `~/storage/shared/Cubby` and the object store on Termux's private storage, because shared storage is a FUSE view with no permission bits, coarse mtimes, slow small-file I/O and reports of corrupted object writes (S30). `core.fileMode false`. inotify does not see other apps' writes there, so the phone polls every ten seconds. After a checkout that added media, `termux-media-scan -r DIR` when the command exists.

## 6. Cross-platform rules

git records three things per path: name, mode, content. That is why this list is finite.

| Difference | What would ping-pong | Rule | Where |
|---|---|---|---|
| Line endings | CRLF on Windows | `-text`, `autocrlf false` | 5.3 |
| Executable bit | Windows and Android cannot store it | `core.fileMode` probed; forced off on Android; where off, git never records a mode change | 5.3 |
| Symlinks | text file on Windows | excluded on the client, rejected on the server | 5.5, 4.6 |
| Case | macOS and Windows fold `A` and `a` | new colliding path excluded; push rejected | 5.5, 4.6 |
| Unicode normalization | macOS returns NFD | `core.precomposeunicode true` | 5.3 |
| Illegal characters and names | Windows refuses them | excluded and rejected | 5.5, 4.6 |
| Path length | Windows 260 | `core.longpaths true`; components over 255 bytes rejected | 5.3, 4.6 |
| `.git` look-alikes | `.GIT`, `git~1`, NTFS streams | `protectNTFS`, `protectHFS`, `fsck.hasDotgit error` | 5.3, 4.5 |
| Nested repositories | gitlinks nobody can resolve | excluded and rejected | 5.5, 4.6 |
| Timestamps | not recorded | restored from commit author dates | 5.4 step 8 |

Portability rules for the script, enforced by `shellcheck` and by CI on all three desktop platforms: bash 3.2 (macOS stock), so no `mapfile`, associative arrays or `${var,,}`; no `flock`, `timeout`, `readlink -f`, `stat -c`, `sed -i`, `date -d`; sizes from `wc -c <`, ages from epoch seconds the script stores, paths from `cd && pwd -P`, in-place edits via temp file and `mv`; every path list crosses a pipe NUL-separated; nothing is ever `eval`ed; awk written for both gawk and BWK awk; shebang `#!/usr/bin/env bash` because Termux has no `/bin/bash`. GNU versus BSD differences that matter: `find -newermt` exists on both, `touch -d @EPOCH` is GNU and `touch -t` is BSD, `date -r FILE` means mtime on both.

## 7. Visibility instead of notifications

No push notifications anywhere (R6). Three surfaces, all visible without a terminal.

**Conflict copies** sit beside the file with the losing device and time in the name. Delete the one you do not want, or rename the copy over the original. Exactly Dropbox.

**`CUBBY-ATTENTION.txt`** at the root of the folder, device-local, never synced. It exists only while something needs a person, and is deleted the moment nothing does, so a normal-looking folder means a normal sync. Contents, one block per item, plain sentences:

- paths excluded and why (5.5), with the rename that would fix each;
- a held mass deletion and the command that releases it;
- a file the merge is waiting on because an application holds it open;
- a sync that has not succeeded for fifteen minutes while online, with the last error verbatim;
- unpushed changes while offline for more than an hour;
- a hand-run git command left the repository on another branch or mid-merge.

Guards, because the attention file is the one thing Cubby writes into the folder: it is in `info/exclude`, the quarantine drops it, the server rejects the name at any depth, the watcher ignores it, it is written to `.cubby-attention.tmp` and renamed, and it is rewritten only when its bytes would change so the watcher never loops on it. Syncthing does the same with `.stignore` and its temp names (S43).

**`cubby status`** prints the status file for the terminal: state `ok | offline | attention`, last success, ahead, behind, conflicts present, excluded count, last error. On the server, `cubby status` prints per-device last seen and last push, and cron mails root when disk or staleness is wrong.

## 8. Big files

No size cap (R12). The cap in revision 1 existed for three reasons; two are settings, one is advice.

### 8.1 What git does with a 20 GB file

| Operation | Behaviour with the settings in 4.5 and 5.3 |
|---|---|
| `add` | Streamed straight into a pack because `* -text ...` proves no conversion applies (*verified*). Without that line git reads the whole file into memory. Cost: one read to hash, one to compress. `core.compression 1` keeps the second cheap on incompressible media. |
| `push`, `fetch` | Above `core.bigFileThreshold` no delta search happens; pack-objects streams the stored bytes. Full size on every changed version. Not resumable: a dropped connection restarts that push, which is why files over 256 MiB travel one per commit (5.4 step 6). |
| `checkout` | Streamed to disk when no filter applies. Blobless clones fetch only the current version. |
| `gc`, `repack` | `gc.bigPackThreshold 1g` keeps large packs instead of rewriting 100 GB weekly; cruft packs hold unreachable objects until `gc.pruneExpire`. |
| Disk | Two copies per device: the file and its compressed blob. Every version ever on the server. |

Platform floors: Linux, macOS and 64-bit Android are fine. Windows is LLP64 and objects over 4 GiB were broken for years; fixes landed in git 2.55 and 2.56 (S13 to S16). Require Git for Windows 2.56 or newer and run the 20 GB round-trip test in 14 before trusting it. 32-bit Android builds share the Windows class of bugs. FAT-formatted storage caps files at 4 GiB regardless.

**Do not raise `core.bigFileThreshold` to get deltas.** Delta search needs both versions and a delta index in memory, `pack.windowMemory` only shrinks the candidate window, and raising the threshold also disables the streaming paths, so `add` and `checkout` would need the file's size in RAM. Revision 1's option for churny files is withdrawn.

### 8.2 Constantly changing big files

VM images, live databases, mail stores, editor caches. Every version is stored whole, so a 10 GB image saved daily is 300 GB a month. In order of simplicity:

1. **Exclude them.** Add the path to `info/exclude`. Their vendors already say not to sync them live.
2. **Sync an export.** A daily dump into the folder from the owning device. Versions become meaningful and bounded.
3. **A separate repository with history expiry** for a whole folder of such files: `~/Cubby/Bulk` backed by `bulk.git`, one more `case` arm in the dispatcher, monthly re-rooting (9.3). `main.git` keeps everything forever.

The settle rule (5.4 step 2) already means a running VM image is never committed mid-write; it syncs when it stops, and the attention file says "still changing" while it runs.

## 9. History, restore, mirror, expiry

### 9.1 Restore

History is the repository (R4). Plain git, from any device:

```sh
git -C ~/Cubby log --oneline -- 'Reports/Q3.docx'                        # versions of a path
git -C ~/Cubby checkout 3f2a9c1^ -- 'Reports/Q3.docx'                     # the version before that commit
git -C ~/Cubby log --diff-filter=D --name-only --oneline                  # everything ever deleted, by whom, when
git -C ~/Cubby checkout "$(git -C ~/Cubby rev-list -1 --before='2026-09-12 18:00' main)" -- 'Reports/'
```

The next pass commits the restore like any change. On a blobless clone the old blob is fetched on demand. From the server: `git -C /srv/cubby/main.git show 3f2a9c1:Reports/Q3.docx > /tmp/Q3.docx`. No pausing, no root, no staging directory.

### 9.2 Mirror

Pull-based (R7). On another machine, with the key named `mirror` and role `ro`:

```sh
git clone --mirror cubby@server:main.git /srv/cubby-mirror.git
cd /srv/cubby-mirror.git
git config fetch.fsckObjects true
git config core.logAllRefUpdates true
git config gc.reflogExpire never
git config remote.origin.fetch 'refs/heads/*:refs/heads/*'     # no plus: a rewritten main is refused, loudly
# cron, every 15 min:  git remote update --prune && git fsck --connectivity-only --no-dangling
```

`--mirror` sets a forced refspec; without the plus, a compromised or corrupted server publishing a rewritten `main` fails the fetch instead of overwriting the good copy. The mirror's cron mails its own root on failure. The server holds no credential.

### 9.3 Expiry

History is permanent by design in `main.git`. For a `bulk.git` that must forget, a documented monthly server job re-roots history, and clients need no re-clone because a fast-forward-only client never needs ancestry beyond the tip it knew. *Verified by the research pass* on a scratch repo:

```sh
# server, local, not a push: a root commit holding today's tree, then main points at it
cd /srv/cubby/bulk.git
tip=$(git rev-parse main)
root=$(git commit-tree -m "history expired $(date -u +%F)" "$tip^{tree}")
git update-ref refs/heads/main "$root" "$tip"
git reflog expire --expire=now --all && git gc --prune=now
```

Client, in the pass, when `git merge-base --is-ancestor LASTKNOWN origin/main` fails: find `root=$(git rev-list --max-parents=0 origin/main)`; require `root^{tree}` to equal `LASTKNOWN^{tree}` (the expiry preserved the tree exactly, so this holds even if others pushed since); then `git rebase --onto "$root" LASTKNOWN` replays local unpushed commits onto the new root with their trees preserved byte for byte, and the normal merge continues. If the trees differ the pass stops with an attention entry, because then it is not an expiry. The mirror is told explicitly, once, to accept the new root for that repository.

## 10. Security model

| Threat | Can | Cannot, and why |
|---|---|---|
| Stolen device key | Read the tree and history. Push deletions and garbage. Fill the disk over time. | Rewrite or delete `main` (`denyNonFastForwards`, `denyDeletes`). Reach a shell, forwarding, another repo or `git-upload-archive` (dispatcher). Alter hooks or config (root-owned, `hooksPath` outside the repo). Hide: every connection is named in the log. Recovery: one `sed` and a `git checkout` on any device. Disk is watched by cron. |
| Compromised server | Read everything. Serve rewritten history. | Overwrite the mirror (non-forced refspec, 9.2). Feed clients corrupt objects (`transfer.fsckObjects`). Encryption at rest is out of scope, as today. |
| Hostile content pushed by a client | Filenames, attributes, ignore files, hooks. | Run anything: R13, nothing synced executes; `info/attributes` outranks in-tree `.gitattributes`; in-tree `.gitignore` is never consulted; hooks are not in the tree and `hooksPath` is pinned; paths are only ever arguments or NUL-separated pathspec files; `.git` look-alikes refused by fsck and the protect settings. |
| Client breaking other platforms | Case collisions, illegal names, symlinks. | Excluded at the source, rejected by the server (5.5, 4.6). |
| Network attacker | First-connection MITM. | Host key pinned by fingerprint at setup, `StrictHostKeyChecking=yes` after. |
| Operator mistake | A bad `gc`, a deleted ref. | Reflog kept forever, weekly and monthly fsck, mirror. |

## 11. Failure catalogue

| Failure | Detected by | Automatic | Manual |
|---|---|---|---|
| Server unreachable | fetch or push ssh error | `offline`, retry every tick, attention only after an hour with unpushed changes | none |
| Two devices push at once | non-fast-forward | fetch, merge, push again, five attempts | none |
| Same file edited on two devices | conflict (7b) | server's version keeps the name, copy beside it | pick one |
| Deleted here, edited there | stage 3 only | edited version restored | none |
| File still being written | settle rule | waits one pass | none |
| File held open by an application | writability probe (7a) | merge skipped this pass, attention "waiting on" | close it, or nothing |
| Pass killed mid-merge | `MERGE_HEAD` at preflight | resolver runs, or `merge --abort` | none |
| Pass killed mid-git | `index.lock` | removed after an hour when no git process is alive | none |
| Loop killed | service manager | restart within five seconds | none |
| Stale Cubby lock | dead pid, no git, age | removed | none |
| Symlink, nested repo, illegal name, case collision | quarantine | excluded, attention entry | rename or move out |
| Manual commit of a bad path | hook rejection (9) | path quarantined, fix committed, pushed | none |
| Manual `git checkout` elsewhere | preflight | attention, nothing pushed | `git checkout main` |
| Folder drive unmounted | pointer file missing | pass stops, attention | mount it |
| Mistaken mass deletion | guard (step 4) and hook | deletions held, everything else syncs | `cubby accept-deletions` or put files back |
| Server disk full | push fails; cron `health` | attention on devices; mail to root | free space |
| Server repo corruption | monthly fsck; `transfer.fsckObjects` on every client fetch | mail; clients refuse bad objects | restore from mirror |
| Mirror stops pulling | its own cron fails | mail on the mirror host | fix it |
| Key revoked mid-session | next authentication | session ends within the `wait` cap | intended |
| Host key rotated | `StrictHostKeyChecking` | attention with the ssh message | `cubby setup --repin` on each device |
| inotify watch limit or queue overflow | `inotifywait` exit; silent overflow | timer and the ten-minute full pass | raise `max_user_watches` or ignore |
| Android kills Termux | nothing runs | Termux:Boot, wake lock, as today | as today |
| Interrupted first clone | checkout stops | blobless clone resumes at the next batch | rerun `git checkout main` |
| Interrupted push of a huge file | push fails | that one commit is retried | none |
| History expired on a bulk repo | ancestry check | rebase onto the new root when trees match | none, or attention if they do not |

## 12. What is lost

- **Empty directories.** git has no representation. A folder appears elsewhere when it holds a file.
- **Symlinks.** Excluded. Mutagen carried them.
- **Instant everything.** Local changes take about three seconds where a watcher exists, remote changes about a second via `wait`; the timer-only fallback is a minute.
- **Resuming a push of one enormous file.** git restarts it. One commit per big file bounds the damage.
- **Disk.** Two copies of the current content per device with a blobless clone.
- **Permanent history in the main repository.** A secret committed by mistake stays in every clone unless the expiry procedure (9.3) is applied to that repository, which is deliberately manual.
- **SFTP browsing from a phone app.** The server speaks only git.
- **A browsable snapshot tree.** `git log` and `git checkout` replace the dated directories.
- **Live databases and VM images.** Section 8.2.

Gained: no Docker, no Mutagen, no PowerShell, no key watcher, no second container, no retention algorithm, no restore script guarding against planted symlinks, no marker files travelling through the tree, no notification service. Atomic multi-file changes, rename-aware transfer, per-path history on every device, selective sync with `git sparse-checkout`, offline commits, restored modification times, server-side validation of every path, a mirror that cannot be overwritten by the thing it mirrors, and a test suite.

## 13. Migration

Cutover, not coexistence: Mutagen and git on the same folder would fight over the pointer file.

1. On every device: `mutagen sync flush Cubby`, then `mutagen sync pause Cubby`. Confirm no pending changes anywhere.
2. On the server: `docker compose stop`. Delete nothing; `shared/` is the import source and the rollback.
3. `server/install.sh`. Import once, excluding the marker directory, and run the hook's rules over the result before any client sees it:
   ```sh
   git --git-dir=/srv/cubby/main.git --work-tree=shared add -A -- . ':!.cubby'
   git --git-dir=/srv/cubby/main.git --work-tree=shared commit -q -m "import from Mutagen tree"
   /usr/local/lib/cubby/hooks/check-tree main     # pre-receive's rules over any ref; fix shared/ and re-import on findings
   ```
4. Add every device's existing `~/.ssh/cubby.pub` to `/etc/cubby/authorized_keys` under its old name.
5. On each device, `cubby setup --adopt ~/Cubby`: init with the separate git dir, remote and config from 5.3, fetch, `git reset -q origin/main` (mixed: index becomes the server's tree, work tree untouched), then show `git status --porcelain -z`. Empty means the copy matched. Any `D` entry means files the server has and this device lacks; `--adopt` refuses to continue and lists them, because the first pass would commit them as deletions. `git checkout -- path` brings them back, or `--adopt --accept-deletions` confirms.
6. `cubby service install ~/Cubby`. Remove the Mutagen daemon registration and, on Windows, the login entry `daemon.ps1 -Register` wrote.
7. Watch `cubby status` and the folders for a day.
8. After a week: `mutagen sync terminate Cubby` everywhere, `docker compose down`, keep `backups/` until nothing in it is worth restoring, then delete `shared/`, `config/`, `keys/`, `offsite/`.

Rollback before step 8: `docker compose up -d`, `mutagen sync resume Cubby`. Changes made through git since step 2 are copied into `shared/` from any device's folder once with `rsync -a --exclude .git`.

## 14. Tests

`tests/` runs with bash, git and a temp directory. Hooks fire on pushes to a `file://` remote, so most of it needs no sshd. `shellcheck` on every script. CI on Ubuntu, macOS (bash 3.2, BSD tools) and Windows (Git Bash).

Server:

- every 4.6 rule rejects with its message, and a fixed follow-up commit is accepted; a bad name in an intermediate commit fixed in the final tree passes;
- non-fast-forward, deletion and other refs refused; `config` unchanged after a hostile push attempt;
- the dispatcher with each allowed command, with `git-upload-pack '/etc'`, `git-upload-archive`, a shell string, empty, and with a key not in the file; `wait` returns on a ref move and at the cap; the `ro` role cannot push;
- `install.sh` twice on a fresh Debian container changes nothing the second time.

Client, two or more clones of one bare repository:

- change, deletion and rename propagate; a renamed big file transfers no blob;
- both modify one file: one copy, identical trees after two passes each, copy content equals the loser's;
- modify/delete, delete/modify, add/add, directory/file; the same conflict resolved by two devices at once converges without a second conflict;
- kill the pass after `git merge` starts; next pass resolves; kill it after commit and before push; nothing lost;
- stale `index.lock` older than an hour with no git process is removed, a fresh one is respected; a live lock directory makes the pass exit 1;
- symlink, nested repo, `CON.txt`, `a?b`, trailing dot, case collision: excluded, listed, everything else syncs; server backstop tested by committing the same by hand;
- a file made unwritable: the probe skips the merge, nothing in the work tree changes, the attention file names it, the merge proceeds when it is writable again; the same with `git merge --ff-only` and `git checkout` to document why they are not used;
- settle rule: a file touched within two seconds waits; a future mtime does not;
- mass deletion held; `accept-deletions` releases with the trailer; the hook accepts the trailer and rejects without it;
- in-tree `.gitignore` excluding `build/`: it syncs; in-tree `.gitattributes` with `text=auto`: no conversion on Windows;
- author date equals newest mtime; after merge, mtimes on the other clone match within the settle window;
- HEAD on another branch: exit 2, nothing pushed; `MERGE_HEAD` at start: resolved;
- attention file: created exactly when an item appears, deleted exactly when the last one clears, never staged, never triggers a pass on its own rewrite;
- big files: a 3 MB file above a 1 MiB threshold lands in a pack, not a loose object, with the attributes line; a 5 GB file round-trips on every CI platform, 20 GB on a nightly Linux and Windows run;
- expiry: re-root a bulk repo; a client with two unpushed commits rebases and pushes; a client whose last-known tree differs stops with attention;
- **convergence fuzz**: four clones perform random creates, edits, renames, deletes and mass deletes for an hour, with induced conflicts, killed passes, locked files and an unmounted root; final trees byte-identical; every blob any clone ever committed is reachable from `main` history or present as a conflict copy.

Integration in a throwaway container with sshd: setup from scratch, key add, sync, revoke cuts the next pass, host key rotation reported.

## 15. Implementation order

1. **Server.** `install.sh`, dispatcher, hooks, `check-tree`, `health`, sshd drop-in, hook tests over `file://`.
2. **Client core.** `setup`, `sync` steps 1 to 10 with quarantine, guard, resolver, probe and mtime restore, `status`, logs, Linux, timer only. Scenario tests.
3. **Loop and boot.** Producers, `wait`, `service install` for Linux, macOS, Windows. CI on three platforms.
4. **Attention file** and `accept-deletions`.
5. **Android.**
6. **Migration.** `--adopt`, section 13 as a README checklist, a dry run on a copy of the real tree.
7. **Mirror.**
8. **Fuzz test** running nightly.
9. **Bulk repository and expiry**, only when a folder needs it.

Repository layout:

```text
server/install.sh           server/sshd.conf            server/shell
server/hooks/pre-receive    server/hooks/check-tree     server/health
client/cubby                client/install.sh           client/exclude           client/attributes
client/run-hidden.vbs       client/android/setup.sh
tests/                      README.md                   REDESIGN.md (deleted once the README covers everything)
```

Deleted: `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `authorized-keys.sh`, `on-key-change.sh`, `session.sh`, `backup/`, `client/*.ps1`, `client/linux/mutagen.service`, `.env.example`.

## 16. Deliberately not built

- **A daemon of ours.** Sessions of seconds, plus one idle `wait`, are what make revocation trivial and the server stateless.
- **Server-side merging.** git merges. Our code names losers and decides what to stage.
- **Automatic text merging.** Correct for source code, wrong for a file sync.
- **Notifications.** The folder shows what needs attention. Cron mails root.
- **Tiered retention on `main.git`.** History is complete; there is nothing to tier. Expiry exists only for a bulk repository and only by hand.
- **Symlink placeholders, size caps, rsync side trees.** Each was in an earlier revision and each was more lines than the problem.
- **A web UI, users, permissions, sharing links, encryption at rest.** One person's files on one person's hardware.
- **Any binary.** If a requirement ever needs one, the answer is another tool, not a Cubby binary.

## Appendix A: verified and unverified claims

Reproduced on git 2.47.3, Linux, during this design:

- `git hash-object -t tree /dev/null` gives the empty tree; `commit-tree` plus `update-ref` bootstraps `main`.
- `git config receive.maxInputSize 4g` parses units (not used any more).
- `* -merge` in `info/attributes` yields stages 1, 2, 3 with ours in the work tree; `git checkout --theirs` writes stage 3. In a bare repository `git merge-tree --write-tree` honours the same attributes (not used in the final design).
- `git ls-files -o --exclude-from=FILE` lists files an in-tree `.gitignore` would hide and hides files in the given list.
- `git add` of a file above `core.bigFileThreshold` is stored loose without `-text` or `autocrlf=false`, and goes straight to a pack with either.
- `git checkout <commit>` exits 0 after "unable to unlink old", HEAD moved, stale file shown modified. `git merge --ff-only` exits 1, HEAD unchanged, other files partially written. `git merge --no-ff` and a real three-way merge exit 2 and change nothing.
- `git update-ref REF NEW OLD` fails when the ref is not at OLD.
- By the research pass: the re-root recipe, `git rebase --onto` preserving local trees, `ls-files -o` listing nested repositories as `dir/` and symlinks, `add -f --pathspec-from-file` staging them as gitlink and symlink.

Not verified by anyone here, marked where they matter:

- Git for Windows end-to-end handling of objects over 4 GiB in 2.56 (8.1); require and test.
- Built-in fsmonitor on Linux since git 2.55 (S11); the timer covers its absence.
- ssh under a Windows S4U task (`/NP`); the VBS fallback covers it.
- inotify blindness on Termux shared storage; the phone polls regardless.
- `skip-worktree` behaviour under merge; irrelevant since symlink placeholders were dropped.

## Appendix B: sources

Primary sources used by the research pass. Numbering as referenced above.

- S1 git `core.*` config: https://git-scm.com/docs/git-config
- S3 `receive.*`: https://git-scm.com/docs/git-config#Documentation/git-config.txt-receivedenyNonFastForwards
- S4 quarantine on rejected pushes: https://git-scm.com/docs/git-receive-pack
- S5 partial clone: https://git-scm.com/docs/partial-clone
- S6 `gc.*`: https://git-scm.com/docs/git-gc
- S7 partial and shallow clone trade-offs: https://github.blog/open-source/git/get-up-to-speed-with-partial-clone-and-shallow-clone/
- S8 gitattributes, `-merge`, precedence: https://git-scm.com/docs/gitattributes
- S9 pack and repack memory: https://git-scm.com/docs/git-repack
- S10 fsmonitor daemon: https://git-scm.com/docs/git-fsmonitor--daemon
- S11 git 2.55 release notes: https://raw.githubusercontent.com/git/git/master/Documentation/RelNotes/2.55.0.adoc
- S13 Git for Windows large objects: https://github.com/git-for-windows/git/pull/2179
- S16 git 2.56 release notes: https://raw.githubusercontent.com/git/git/master/Documentation/RelNotes/2.56.0.adoc
- S18 sshd, authorized_keys options, ForceCommand precedence: https://man.openbsd.org/sshd
- S19 sshd_config, Match keywords: https://man.openbsd.org/sshd_config
- S20 Debian sshd_config: https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html
- S22 OpenSSH `safe_path`: https://raw.githubusercontent.com/openssh/openssh-portable/master/misc.c
- S23 OpenSSH 7.2 release, `restrict`: https://www.openssh.org/txt/release-7.2
- S25 Windows file naming: https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
- S28 `git ls-files` exclude options: https://git-scm.com/docs/git-ls-files
- S30 Termux storage layout: https://github.com/termux/termux-packages/wiki/Termux-file-system-layout
- S31 BSD find `-newermt`: https://man.freebsd.org/cgi/man.cgi?query=find&sektion=1
- S33 `git add --pathspec-from-file`: https://git-scm.com/docs/git-add
- S35 git-restore-mtime: https://github.com/MestreLion/git-tools/blob/main/git-restore-mtime
- S36 push not resumable: https://docs.github.com/en/get-started/using-git/troubleshooting-the-2-gb-push-limit
- S37 Syncthing conflicts and deletion rules: https://docs.syncthing.net/users/syncing.html
- S38 Dropbox conflicted copy: https://help.dropbox.com/organize/conflicted-copy
- S42 Dropbox case conflict: https://help.dropbox.com/organize/case-conflict
- S43 Syncthing ignore and temp names: https://docs.syncthing.net/users/ignoring.html
- S44 inotify limits: https://watchexec.github.io/docs/inotify-limits.html
- S45 inotify(7): https://man7.org/linux/man-pages/man7/inotify.7.html
- S49 schtasks `/NP`: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create
- S50 Log on as a batch job: https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/log-on-as-a-batch-job
- S52 Termux:Boot: https://github.com/termux/termux-boot/blob/master/README.md
- S53 phantom process killer: https://github.com/termux/termux-app/issues/2366
- S54 racy-git: https://git-scm.com/docs/racy-git
- S59 git replace: https://git-scm.com/docs/git-replace
- S61 prior art: SparkleShare issues 519, 111, 1744, 335 at https://github.com/hbons/SparkleShare/issues ; https://github.com/rmayr/dvcs-autosync ; https://github.com/gitwatch/gitwatch ; https://github.com/simonthum/git-sync ; https://git-annex.branchable.com/direct_mode/
- S63 APFS normalization: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html
