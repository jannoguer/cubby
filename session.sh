#!/bin/sh
# Forced command in front of every served key; $1 is the key's name, read back
# by the entrypoint's report.
case "${SSH_ORIGINAL_COMMAND-}" in
    # A forced command replaces sshd's built-in sftp; Mutagen installs its agent over scp.
    internal-sftp) exec /usr/lib/ssh/sftp-server ;;
    '') exec /bin/sh ;;
    *) exec /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;
esac
