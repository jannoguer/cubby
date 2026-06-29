FROM alpine:3.21

RUN apk add --no-cache openssh-server openssh-keygen

RUN printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'AllowUsers syncuser' \
    'AllowTcpForwarding no' \
    'X11Forwarding no' \
    'PermitTunnel no' \
    'AuthorizedKeysFile /config/home/.ssh/authorized_keys' \
    'HostKey /config/ssh_host_keys/ssh_host_ed25519_key' \
    >> /etc/ssh/sshd_config

RUN mkdir -p /config \
    && adduser -D -h /config/home -s /bin/sh -u 1000 syncuser \
    && sed -i 's|^syncuser:!:|syncuser:*:|' /etc/shadow

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
