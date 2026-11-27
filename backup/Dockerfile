FROM alpine:3.24

RUN apk add --no-cache rsync

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

# uid 1000 owns everything under /shared, so no capability is needed to read it.
USER 1000:1000

CMD ["/entrypoint.sh"]
