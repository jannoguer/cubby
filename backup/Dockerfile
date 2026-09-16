FROM alpine:3.24

RUN apk add --no-cache rsync \
    && adduser -D -H -u 1000 -s /sbin/nologin cubby

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# uid 1000 owns everything under /shared, so no capability is needed to read it.
USER 1000:1000

CMD ["/entrypoint.sh"]
