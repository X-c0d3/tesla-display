#!/usr/bin/env bash
# สร้าง build/Tesla Display.app (desktop app) จาก source ใน repo
#   ./scripts/build-app.sh            # build อย่างเดียว -> build/Tesla Display.app
#   ./scripts/build-app.sh --install  # build + ปิดแอปเดิม + คัดลอกไป /Applications + เปิดแอป
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tesla Display.app"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling…"
swiftc -O -swift-version 5 -parse-as-library -import-objc-header "$ROOT/app/CGVirtualDisplay.h" "$ROOT/app/TeslaDisplay.swift" -o "$APP/Contents/MacOS/TeslaDisplay"
swiftc -O "$ROOT/scripts/mac-capture.swift" -o "$APP/Contents/Resources/mac-capture"
swiftc -O "$ROOT/scripts/mac-input-agent.swift" -o "$APP/Contents/Resources/mac-input-agent"

# mediamtx สำหรับโหมด Local (ดาวน์โหลดจาก GitHub release ครั้งเดียว + ตรวจ sha256)
MTX_VER="v1.11.3"
MTX_ARCH="$([[ "$(uname -m)" == "arm64" ]] && echo arm64 || echo amd64)"
MTX_TGZ="mediamtx_${MTX_VER}_darwin_${MTX_ARCH}.tar.gz"
MTX_DIR="$ROOT/.cache/mediamtx-$MTX_VER-$MTX_ARCH"
if [[ ! -x "$MTX_DIR/mediamtx" ]]; then
  mkdir -p "$MTX_DIR/dl"
  BASE="https://github.com/bluenviron/mediamtx/releases/download/$MTX_VER"
  curl -fsSL "$BASE/$MTX_TGZ" -o "$MTX_DIR/dl/$MTX_TGZ"
  curl -fsSL "$BASE/$MTX_TGZ.sha256sum" -o "$MTX_DIR/dl/$MTX_TGZ.sha256sum"
  (cd "$MTX_DIR/dl" && shasum -a 256 -c "$MTX_TGZ.sha256sum")
  tar -xzf "$MTX_DIR/dl/$MTX_TGZ" -C "$MTX_DIR" mediamtx
  rm -rf "$MTX_DIR/dl"
fi
cp "$MTX_DIR/mediamtx" "$APP/Contents/Resources/mediamtx"

# Caddy สำหรับโหมด Local: เสิร์ฟหน้าเว็บ + HTTPS บน Mac เอง (ดาวน์โหลดครั้งเดียว + ตรวจ sha512)
CADDY_VER="2.8.4"
CADDY_TGZ="caddy_${CADDY_VER}_mac_${MTX_ARCH}.tar.gz"
CADDY_DIR="$ROOT/.cache/caddy-$CADDY_VER-$MTX_ARCH"
if [[ ! -x "$CADDY_DIR/caddy" ]]; then
  mkdir -p "$CADDY_DIR/dl"
  BASE="https://github.com/caddyserver/caddy/releases/download/v$CADDY_VER"
  curl -fsSL "$BASE/$CADDY_TGZ" -o "$CADDY_DIR/dl/$CADDY_TGZ"
  curl -fsSL "$BASE/caddy_${CADDY_VER}_checksums.txt" -o "$CADDY_DIR/dl/checksums.txt"
  (cd "$CADDY_DIR/dl" && grep " $CADDY_TGZ\$" checksums.txt | shasum -a 512 -c)
  tar -xzf "$CADDY_DIR/dl/$CADDY_TGZ" -C "$CADDY_DIR" caddy
  rm -rf "$CADDY_DIR/dl"
fi
cp "$CADDY_DIR/caddy" "$APP/Contents/Resources/caddy"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"

# ไอคอน
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$ROOT/app/make-icon.swift" "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tesla Display</string>
  <key>CFBundleDisplayName</key><string>Tesla Display</string>
  <key>CFBundleIdentifier</key><string>local.tesla-screenshare</string>
  <key>CFBundleExecutable</key><string>TeslaDisplay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# ad-hoc sign (build ใหม่ = signature ใหม่ -> macOS อาจถามสิทธิ์ซ้ำ)
codesign --force -s - "$APP/Contents/Resources/mac-capture" "$APP/Contents/Resources/mac-input-agent" \
  "$APP/Contents/Resources/mediamtx" "$APP/Contents/Resources/caddy"
codesign --force -s - "$APP"

echo "built: $APP"
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
