#!/usr/bin/env bash
# สร้าง build/Tesla Display.app (desktop app) จาก source ใน repo
#   ./scripts/build-app.sh            # build อย่างเดียว -> build/Tesla Display.app
#   ./scripts/build-app.sh --install  # build + ปิดแอปเดิม + คัดลอกไป /Applications + เปิดแอป
#
# ตัวแปร (ไม่บังคับ — ใช้ตอน build บน GitHub Actions):
#   UNIVERSAL=1                 build ทั้ง Apple Silicon + Intel ในไฟล์เดียว (ค่าเริ่มต้น = เฉพาะเครื่องนี้)
#   VERSION=1.2.0               เลขเวอร์ชันของแอป (ค่าเริ่มต้น 1.0)
#   PAIR_URL=https://…/pair     ค่าเริ่มต้นของ Pair server (Direct Wi-Fi) ในแอป — ว่าง = ผู้ใช้กรอกเอง
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "build-app.sh builds the macOS app — run it on a Mac (needs Xcode Command Line Tools)." >&2
  echo "On the server use: docker compose up -d --build  (behind nginx: add -f docker-compose.yml -f compose.behind-proxy.yml)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tesla Display.app"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1
VERSION="${VERSION:-1.0}"
VERSION="${VERSION#v}"
MIN_MACOS="15.0"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")
fi

TMP="$ROOT/build/.tmp"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

# compile Swift ทีละ arch แล้วรวมเป็นไฟล์เดียวด้วย lipo
compile() {
  local out="$1"; shift
  local slices=()
  for arch in "${ARCHS[@]}"; do
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" "$@" -o "$TMP/$(basename "$out").$arch"
    slices+=("$TMP/$(basename "$out").$arch")
  done
  lipo -create "${slices[@]}" -output "$out"
}

echo "compiling (${ARCHS[*]})…"
compile "$APP/Contents/MacOS/TeslaDisplay" -swift-version 5 -parse-as-library \
  -import-objc-header "$ROOT/app/CGVirtualDisplay.h" "$ROOT/app/TeslaDisplay.swift"
compile "$APP/Contents/Resources/mac-capture" "$ROOT/scripts/mac-capture.swift"
compile "$APP/Contents/Resources/mac-input-agent" "$ROOT/scripts/mac-input-agent.swift"

# ชื่อ arch ของไฟล์ release: Go ใช้ amd64 แทน x86_64
goarch() { [[ "$1" == "arm64" ]] && echo arm64 || echo amd64; }

# mediamtx สำหรับโหมด Direct Wi-Fi (ดาวน์โหลดจาก GitHub release ครั้งเดียว + ตรวจ sha256)
MTX_VER="v1.11.3"
fetch_mediamtx() {
  local a; a="$(goarch "$1")"
  local tgz="mediamtx_${MTX_VER}_darwin_${a}.tar.gz" dir="$ROOT/.cache/mediamtx-$MTX_VER-$a"
  if [[ ! -x "$dir/mediamtx" ]]; then
    mkdir -p "$dir/dl"
    local base="https://github.com/bluenviron/mediamtx/releases/download/$MTX_VER"
    curl -fsSL "$base/$tgz" -o "$dir/dl/$tgz"
    curl -fsSL "$base/$tgz.sha256sum" -o "$dir/dl/$tgz.sha256sum"
    (cd "$dir/dl" && shasum -a 256 -c "$tgz.sha256sum" >/dev/null)
    tar -xzf "$dir/dl/$tgz" -C "$dir" mediamtx
    rm -rf "$dir/dl"
  fi
  echo "$dir/mediamtx"
}

MTX=()
for arch in "${ARCHS[@]}"; do
  MTX+=("$(fetch_mediamtx "$arch")")
done
lipo -create "${MTX[@]}" -output "$APP/Contents/Resources/mediamtx"

# ไอคอน
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/app/make-icon.swift" "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

xml_escape() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; echo "${s//>/&gt;}"; }

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tesla Display</string>
  <key>CFBundleDisplayName</key><string>Tesla Display</string>
  <key>CFBundleIdentifier</key><string>local.tesla-screenshare</string>
  <key>CFBundleExecutable</key><string>TeslaDisplay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml_escape "$VERSION")</string>
  <key>CFBundleVersion</key><string>$(xml_escape "$VERSION")</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>TDPairURL</key><string>$(xml_escape "${PAIR_URL:-}")</string>
</dict>
</plist>
EOF
rm -rf "$TMP"

# ad-hoc sign (build ใหม่ = signature ใหม่ -> macOS อาจถามสิทธิ์ซ้ำ)
codesign --force -s - "$APP/Contents/Resources/mac-capture" "$APP/Contents/Resources/mac-input-agent" \
  "$APP/Contents/Resources/mediamtx"
codesign --force -s - "$APP"

echo "built: $APP (v$VERSION, ${ARCHS[*]})"
[[ $INSTALL == 1 ]] || echo "ติดตั้ง: ./scripts/build-app.sh --install"

if [[ $INSTALL == 1 ]]; then
  DEST="/Applications/Tesla Display.app"
  # ปิดแอปที่เปิดอยู่ (Quit จะหยุดการส่งภาพและลบจอเสมือนให้เรียบร้อย)
  osascript -e 'tell application "Tesla Display" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -f "$DEST/Contents/MacOS/TeslaDisplay" >/dev/null || break; sleep 1; done
  pkill -f "$DEST/Contents/MacOS/TeslaDisplay" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "installed: $DEST"
  open "$DEST"
  echo
  echo "build ใหม่ = signature ใหม่: ถ้าส่งภาพไม่ได้ ให้ลบ Tesla Display ใน System Settings >"
  echo "Privacy & Security > Screen & System Audio Recording และ Accessibility แล้วเพิ่มใหม่ จากนั้น Quit/เปิดแอปอีกครั้ง"
fi
