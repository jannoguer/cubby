#!/bin/sh
# Forced command in front of every served key: records this connection's sshd
# process under the key's name so cubby-on-key-change can end only that client.
set -u

# The user's shell may sit between sshd and this script.
pid=$PPID
while [ "$pid" -gt 1 ]; do
    case "$(sed -n 's/^Name:[[:space:]]*//p' "/proc/$pid/status")" in sshd*) break ;; esac
    pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status")
done
dir="/run/cubby-sessions/$1"
mkdir -p "$dir" && : > "$dir/$pid"
for p in "$dir"/*; do
    [ -e "$p" ] && [ ! -d "/proc/${p##*/}" ] && rm -f "$p"
done

case "${SSH_ORIGINAL_COMMAND-}" in
    # A forced command replaces sshd's built-in sftp; Mutagen installs its agent over scp.
    internal-sftp) exec /usr/lib/ssh/sftp-server ;;
    '') exec /bin/sh ;;
    *) exec /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;
esac
