FROM alpine:3.24

RUN apk add --no-cache openssh-server openssh-sftp-server openssh-keygen

# sshd keeps the first value seen per keyword and the stock file sets some of
# these, so only the Include placed ahead of them can override.
RUN mkdir -p /etc/ssh/sshd_config.d \
    && printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'AuthenticationMethods publickey' \
    'AllowGroups cubby' \
    'AllowTcpForwarding no' \
    'AllowAgentForwarding no' \
    'X11Forwarding no' \
    'PermitTunnel no' \
    'PermitUserRC no' \
    'AuthorizedKeysFile /run/cubby/authorized_keys/%u' \
    'HostKey /config/ssh_host_keys/ssh_host_ed25519_key' \
    'LoginGraceTime 30' \
    'MaxAuthTries 3' \
    'ClientAliveInterval 60' \
    'ClientAliveCountMax 3' \
    > /etc/ssh/sshd_config.d/10-cubby.conf

# adduser -D writes "!" to /etc/shadow, which sshd treats as locked even for key auth.
# The root fs is read-only: the entrypoint writes passwd and shadow, per-key users included, into /run.
RUN mkdir -p /config \
    && adduser -D -h /config/home -s /bin/sh -u 1000 cubby \
    && sed -i 's|^cubby:!:|cubby:*:|' /etc/shadow \
    && for f in passwd shadow; do mv /etc/$f /etc/$f.base && ln -s /run/cubby/$f /etc/$f; done

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
