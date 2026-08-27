FROM alpine:3.24

RUN apk add --no-cache openssh-server openssh-keygen

# A drop-in, not an append: sshd keeps the first value seen for a keyword and
# the stock config already sets some of these, so only an Include (its line 1)
# can override them.
RUN mkdir -p /etc/ssh/sshd_config.d \
    && printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'AllowUsers syncuser' \
    'AllowTcpForwarding no' \
    'AllowAgentForwarding no' \
    'X11Forwarding no' \
    'PermitTunnel no' \
    'AuthorizedKeysFile /etc/ssh/authorized_keys/%u' \
    'HostKey /config/ssh_host_keys/ssh_host_ed25519_key' \
    'ClientAliveInterval 60' \
    'ClientAliveCountMax 3' \
    > /etc/ssh/sshd_config.d/10-cubby.conf

# adduser -D leaves "!" in /etc/shadow, which sshd reads as a locked account and
# refuses even for key auth; "*" denies password login without locking.
RUN mkdir -p /config \
    && adduser -D -h /config/home -s /bin/sh -u 1000 syncuser \
    && sed -i 's|^syncuser:!:|syncuser:*:|' /etc/shadow

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
