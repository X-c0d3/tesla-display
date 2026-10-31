#!/usr/bin/env bash
# แพ็กไฟล์ที่ server (NAS / Docker) ต้องใช้ -> build/tesla-screenshare-server.tgz
#   ./scripts/package-server.sh
#   scp build/tesla-screenshare-server.tgz root@<SERVER-IP>:/opt/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tesla-screenshare-server.tgz"
mkdir -p "$ROOT/build"

cd "$ROOT"
COPYFILE_DISABLE=1 tar -czf "$OUT" --exclude='.DS_Store' \
  Dockerfile docker docker-compose.yml compose.behind-proxy.yml Caddyfile mediamtx.yml .env.example relay web nginx

echo "packed: $OUT"
tar -tzf "$OUT" | sed 's/^/  /'
