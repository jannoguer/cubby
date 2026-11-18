FROM nginx:alpine

COPY nginx.conf auth.js totp.js creds.js listing.js english.txt /web/
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

# uid 1000 owns everything under /shared, so it can read it all.
USER 1000:1000

ENTRYPOINT ["/entrypoint.sh"]
