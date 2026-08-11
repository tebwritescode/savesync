# One file, no dependencies -- so the image is the Node base plus 8 KB of
# JavaScript, and `docker build` never touches a package registry.
FROM node:22-alpine

WORKDIR /app
COPY server.js ./

# Saves live on a volume, not in the image: `docker compose down` must never
# be able to take a playthrough with it.
#
# /data is created and chowned HERE, before VOLUME, because Docker seeds a
# fresh named volume from the image path -- ownership included.  Without this
# the volume would appear owned by root and the unprivileged process below
# could not write a single save.
RUN mkdir -p /data && chown node:node /data
VOLUME /data
ENV DATA_DIR=/data
ENV PORT=8787
EXPOSE 8787

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD node -e "require('http').get('http://127.0.0.1:'+(process.env.PORT||8787)+'/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "server.js"]
