FROM alpine:3.24

RUN apk add --no-cache openssh-server openssh-keygen rsync

# sshd keeps the first value seen per keyword and the stock file sets some of
# these, so only the Include placed ahead of them can override.
RUN mkdir -p /etc/ssh/sshd_config.d \
    && printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'AuthenticationMethods publickey' \
    'AllowUsers syncuser' \
    'AllowTcpForwarding no' \
    'AllowAgentForwarding no' \
    'X11Forwarding no' \
    'PermitTunnel no' \
    'AuthorizedKeysFile none' \
    'AuthorizedKeysCommand /usr/local/bin/cubby-authorized-keys %u' \
    'AuthorizedKeysCommandUser nobody' \
    'HostKey /config/ssh_host_keys/ssh_host_ed25519_key' \
    'LoginGraceTime 30' \
    'MaxAuthTries 3' \
    'ClientAliveInterval 60' \
    'ClientAliveCountMax 3' \
    > /etc/ssh/sshd_config.d/10-cubby.conf

# adduser -D writes "!" to /etc/shadow, which sshd treats as locked even for key auth.
RUN mkdir -p /config \
    && adduser -D -h /config/home -s /bin/sh -u 1000 syncuser \
    && sed -i 's|^syncuser:!:|syncuser:*:|' /etc/shadow

COPY client/ /opt/cubby/client/

# sshd refuses an AuthorizedKeysCommand that is not root-owned and unwritable by others.
COPY authorized-keys.sh /usr/local/bin/cubby-authorized-keys
COPY on-key-change.sh /usr/local/bin/cubby-on-key-change
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/cubby-authorized-keys /usr/local/bin/cubby-on-key-change /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
