# Syncthing's official binary on a plain Alpine base. Copying the binary rather
# than building on the upstream image leaves behind its /var/syncthing volume,
# its 8384 GUI address and its entrypoint, none of which Cubby wants.
FROM syncthing/syncthing:2 AS upstream

FROM alpine:3.24

# bash, curl and jq for the cubby script; su-exec to drop privileges; coreutils
# because the script uses GNU df --output and date -d, which BusyBox lacks.
RUN apk add --no-cache bash coreutils curl jq su-exec

COPY --from=upstream /bin/syncthing /usr/local/bin/syncthing
COPY --chmod=755 cubby entrypoint /usr/local/bin/

ENV PUID=1000 \
    PGID=1000 \
    CUBBY_HOME=/srv/cubby \
    CUBBY_FOLDER=/srv/cubby/Cubby \
    CUBBY_STHOME=/srv/cubby/config \
    CUBBY_SOCK=/run/cubby/api.sock \
    CUBBY_MAX_AGE_DAYS=365 \
    CUBBY_DISK_PCT=85 \
    CUBBY_STALE_DAYS=7

# The sync protocol, and nothing else. Discovery, relaying and the GUI are off.
EXPOSE 22000/tcp

# Replaces the cron line that used to mail root: cubby health exits non-zero
# when it has something to report, so docker ps shows the container unhealthy
# and docker inspect keeps the text of the last few reports.
HEALTHCHECK --interval=5m --timeout=30s --start-period=2m --retries=2 \
    CMD cubby health

ENTRYPOINT ["entrypoint"]
