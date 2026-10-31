#!/bin/sh
# รัน mediamtx + relay + Caddy ใน container เดียว ถ้าตัวใดตัวหนึ่งหยุด ให้หยุดทั้งหมด
# (docker จะ restart container ให้ตาม restart: unless-stopped)
set -eu

: "${DOMAIN:?set DOMAIN in .env}"
: "${PUBLISH_TOKEN:?set PUBLISH_TOKEN in .env}"
: "${CONTROL_PIN:?set CONTROL_PIN in .env}"

# Caddy: ที่อยู่ของเว็บ (ปกติ = DOMAIN ได้ HTTPS อัตโนมัติ, หลัง reverse proxy = ":80" เป็น HTTP)
export SITE_ADDRESS="${SITE_ADDRESS:-$DOMAIN}"
# mediamtx: address ที่ Tesla/Mac ใช้ส่ง UDP มาหา (ปกติ = DOMAIN)
export MTX_WEBRTCADDITIONALHOSTS="${MTX_WEBRTCADDITIONALHOSTS:-$DOMAIN}"

# ใส่ชื่อบริการหน้าแต่ละบรรทัดของ log
PIDS=""
run() {
    name="$1"; shift
    ( "$@" 2>&1 | while IFS= read -r line; do printf '[%s] %s\n' "$name" "$line"; done ) &
    PIDS="$PIDS $!"
}

run mediamtx mediamtx /etc/tesla-display/mediamtx.yml
run relay    python -u /opt/tesla-display/relay.py
run caddy    caddy run --config /etc/tesla-display/Caddyfile --adapter caddyfile

trap 'kill 0 2>/dev/null; exit 0' TERM INT

# รอจนกว่าบริการใดบริการหนึ่งจะจบ แล้วหยุดทั้งหมด
while :; do
    for p in $PIDS; do
        if ! kill -0 "$p" 2>/dev/null; then
            echo "[entrypoint] a service exited — stopping container"
            kill 0 2>/dev/null
            exit 1
        fi
    done
    sleep 2
done
