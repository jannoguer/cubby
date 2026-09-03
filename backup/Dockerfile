FROM alpine:3.24

RUN apk add --no-cache rsync

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

# uid 1000 owns everything under /shared, so no capability is needed to read it.
USER 1000:1000

CMD ["/backup.sh"]
