FROM alpine:3.24

# ssh refuses to run for a uid without a passwd entry.
RUN apk add --no-cache rsync openssh-client \
    && adduser -D -H -u 1000 -s /sbin/nologin backup

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

# uid 1000 owns everything under /shared, so no capability is needed to read it.
USER 1000:1000
ENV HOME=/tmp

CMD ["/backup.sh"]
