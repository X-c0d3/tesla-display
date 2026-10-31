# Tesla Display server — image เดียวรวม mediamtx (WebRTC) + Caddy (HTTPS/proxy) + input relay (Python)
#   docker compose up -d --build
FROM bluenviron/mediamtx:1.11.3 AS mediamtx
FROM caddy:2.8.4-alpine AS caddy

FROM python:3.12-alpine
RUN pip install --no-cache-dir websockets==13.1

COPY --from=mediamtx /mediamtx /usr/local/bin/mediamtx
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

COPY mediamtx.yml Caddyfile /etc/tesla-display/
COPY relay/relay.py /opt/tesla-display/relay.py
COPY web /srv
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Caddy เก็บใบรับรองไว้ที่ /data (mount เป็น volume เพื่อไม่ต้องขอใหม่ทุกครั้งที่ rebuild)
ENV XDG_DATA_HOME=/data XDG_CONFIG_HOME=/config
VOLUME ["/data", "/config"]

EXPOSE 80 443 8189/udp
ENTRYPOINT ["/entrypoint.sh"]
