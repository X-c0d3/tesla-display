#!/usr/bin/env bash
# ทดสอบว่า Tesla browser เปิดหน้าเว็บจาก Mac ในวง Wi-Fi เดียวกันได้แบบไหน (ไม่ใช้ server ข้างนอก)
#   1. Mac เปิด Internet Sharing -> Tesla ต่อ Wi-Fi ของ Mac
#   2. ./dev/tesla-local-test.sh
#   3. บน Tesla ลองเปิด URL ที่สคริปต์พิมพ์ออกมาทีละอัน แล้วจดผล
# กด Ctrl+C เพื่อหยุด
set -euo pipefail

DIR="$(mktemp -d)"
trap 'kill 0 2>/dev/null; rm -rf "$DIR"' EXIT

# IP ของ Mac ทุก interface (Internet Sharing = 192.168.2.1 เสมอ)
IPS=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2}')
SAN=$(for ip in $IPS; do printf "IP:%s," "$ip"; done)
SAN="${SAN%,}"

openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=Tesla Display Test" \
  -addext "subjectAltName=$SAN" -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null

cat > "$DIR/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Tesla local test</title>
<style>body{background:#111;color:#eee;font:28px system-ui;padding:40px}b{color:#4f4}</style></head>
<body><h1>✅ Tesla เปิดหน้านี้ได้</h1>
<p>protocol: <b id="p"></b></p>
<p>WebRTC (RTCPeerConnection): <b id="w"></b></p>
<p>WebSocket: <b id="s"></b></p>
<p>WebGL / GPU: <b id="g"></b></p>
<p>H.264 1080p30 decode: <b id="d1"></b></p>
<p>H.264 1080p60 decode: <b id="d2"></b></p>
<p>screen: <b id="sc"></b></p>
<p style="font-size:18px;color:#999" id="ua"></p>
<script>
p.textContent = location.protocol + '//' + location.host;
w.textContent = typeof RTCPeerConnection === 'function' ? 'yes' : 'NO';
s.textContent = typeof WebSocket === 'function' ? 'yes' : 'NO';
ua.textContent = navigator.userAgent;
sc.textContent = screen.width + 'x' + screen.height + ' @' + (window.devicePixelRatio || 1) + 'x, viewport ' + innerWidth + 'x' + innerHeight;
try {
  const gl = document.createElement('canvas').getContext('webgl2') || document.createElement('canvas').getContext('webgl');
  if (!gl) g.textContent = 'NO WebGL';
  else {
    const ext = gl.getExtension('WEBGL_debug_renderer_info');
    g.textContent = (gl instanceof WebGL2RenderingContext ? 'WebGL2 · ' : 'WebGL1 · ') +
      (ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
  }
} catch (e) { g.textContent = 'error: ' + e.message; }
// powerEfficient = ถอดรหัสด้วย hardware
async function dec(el, fps) {
  if (!navigator.mediaCapabilities) { el.textContent = 'unknown'; return; }
  const r = await navigator.mediaCapabilities.decodingInfo({ type: 'webrtc',
    video: { contentType: 'video/H264', width: 1920, height: 1080, bitrate: 8e6, framerate: fps } });
  el.textContent = (r.supported ? 'supported' : 'NOT supported') +
    (r.smooth ? ' · smooth' : ' · not smooth') + (r.powerEfficient ? ' · HARDWARE' : ' · software');
}
dec(d1, 30); dec(d2, 60);
</script></body></html>
EOF

cat > "$DIR/serve.py" <<'EOF'
import http.server, ssl, sys, functools
port, tls, root = int(sys.argv[1]), sys.argv[2] == "tls", sys.argv[3]
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *a):
        print(f"[{'https' if tls else 'http'}:{port}] {self.client_address[0]} {fmt % a}", flush=True)
srv = http.server.ThreadingHTTPServer(("0.0.0.0", port), functools.partial(H, directory=root))
if tls:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{root}/cert.pem", f"{root}/key.pem")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
EOF

python3 -I "$DIR/serve.py" 8080 plain "$DIR" &
python3 -I "$DIR/serve.py" 8443 tls "$DIR" &
sleep 1

echo
echo "บน Tesla ลองเปิดทีละอัน (ใช้ IP ของวงที่ Tesla ต่ออยู่ — Internet Sharing = 192.168.2.1):"
for ip in $IPS; do
  echo "  A) http://$ip:8080"
  echo "  B) https://$ip:8443   (ถ้าขึ้นหน้าเตือน ให้ลองกด Advanced / Proceed)"
done
echo
echo "จดผลแต่ละอัน: เปิดได้ / ขึ้นหน้าเตือนแต่กดผ่านได้ / เปิดไม่ได้เลย"
echo "บรรทัดด้านล่างจะขึ้นเมื่อ Tesla เข้ามาถึง Mac แล้ว (Ctrl+C เพื่อหยุด)"
wait
