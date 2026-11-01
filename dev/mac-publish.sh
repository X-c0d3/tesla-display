#!/usr/bin/env bash
# ส่งหน้าจอ Mac ไป mediamtx บน NAS ผ่าน WHIP
# จับภาพด้วย ScreenCaptureKit (scripts/mac-capture.swift) แล้วให้ ffmpeg (>= 8) encode + ส่ง WHIP
#
#   ./dev/mac-publish.sh list                 # ดูหมายเลขจอ (เลขเดียวกับ mac-input-agent)
#   SCREEN_URL=https://screen.example.com TOKEN=xxx ./dev/mac-publish.sh 1
#
# ตัวแปร: SCREEN_URL, TOKEN (บังคับ) | FPS=30 | BITRATE=8M
#         SIZE=1920x1200 (ย่อให้พอดีกรอบนี้โดยรักษาสัดส่วน, SIZE= ว่าง = ขนาดเดิม)
#         AUDIO=1 (ส่งเสียงระบบเป็น Opus, AUDIO=0 = ภาพอย่างเดียว)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAP="$ROOT/.bin/mac-capture"
SRC="$ROOT/scripts/mac-capture.swift"

# คอมไพล์ตัวจับภาพครั้งแรก หรือเมื่อ source เปลี่ยน
if [[ ! -x "$CAP" || "$SRC" -nt "$CAP" ]]; then
  echo "compiling mac-capture…" >&2
  mkdir -p "$ROOT/.bin"
  swiftc -O "$SRC" -o "$CAP"
fi

DEV="${1:-}"
if [[ -z "$DEV" ]]; then echo "usage: $0 list | <screen-index>"; exit 1; fi
if [[ "$DEV" == "list" ]]; then
  "$CAP" list
  exit 0
fi

: "${SCREEN_URL:?set SCREEN_URL e.g. https://screen.example.com}"
: "${TOKEN:?set TOKEN (PUBLISH_TOKEN from .env)}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-8M}"
SIZE="${SIZE-1920x1200}"

read -r W H < <("$CAP" size "$DEV" "$SIZE")
echo "publishing display $DEV (${W}x${H} @ ${FPS}fps, $BITRATE) -> ${SCREEN_URL%/}/screen/whip" >&2

AUDIO_IN=() AUDIO_OUT=() FIFO=""
if [[ "${AUDIO:-1}" == "1" ]]; then
  TMP="$(mktemp -d)"; FIFO="$TMP/audio.fifo"; mkfifo "$FIFO"
  trap 'rm -rf "$TMP"' EXIT
  AUDIO_IN=(-f f32le -ar 48000 -ac 2 -thread_queue_size 1024 -i "$FIFO")
  AUDIO_OUT=(-map 0:v -map 1:a -c:a libopus -b:a 128k -ar 48000)
fi

# keyframe เล็ก (VBV 1/8 วินาที) = ส่งเป็นก้อนสั้น -> jitter buffer บนรถต่ำ (BITRATE เช่น 8M -> 1000k)
BUFSIZE="$(( ${BITRATE%M} * 1000 / 8 ))k"
"$CAP" stream "$DEV" "$W" "$H" "$FPS" $FIFO | ffmpeg -hide_banner -loglevel warning \
  -f rawvideo -pix_fmt nv12 -color_range tv -video_size "${W}x${H}" -framerate "$FPS" -thread_queue_size 64 -i - \
  ${AUDIO_IN[@]+"${AUDIO_IN[@]}"} ${AUDIO_OUT[@]+"${AUDIO_OUT[@]}"} \
  -c:v libx264 -preset veryfast -tune zerolatency -profile:v main -bf 0 -g "$((FPS * 2))" -sc_threshold 0 \
  -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BUFSIZE" \
  -f whip -authorization "$TOKEN" "${SCREEN_URL%/}/screen/whip"
