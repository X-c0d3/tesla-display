# AGENTS.md

Guide for AI coding agents working on this repo. Human-facing docs: `README.md` (Thai), `dev/LOCAL-TEST.md`.

## What this is
**Tesla Display** — use a Tesla's center screen (browser) as a 2nd monitor for a Mac, mainly for coding while parked.
Video is H.264 over WebRTC; touch/keyboard/gamepad from the car control the Mac; Mac audio plays in the car.
Nothing is installed on the Tesla — it only opens a URL.

Two routes (selectable in the app):
- **Direct Wi-Fi** — the Mac is the whole server (bundled Caddy + mediamtx + input agent). Tesla joins the Mac's
  Wi-Fi (Internet Sharing, Mac IP is always `192.168.2.1`) and opens `https://<mac-ip>:8443` (self-signed) or
  `http://<mac-ip>:8080`. PIN-protected. No outside server.
- **Home Server** — Mac publishes via WHIP to a Docker stack on the user's NAS (Caddy + mediamtx + Python relay);
  Tesla opens `https://<DOMAIN>`. Works when Mac and car are on different networks.

## Layout
```
app/TeslaDisplay.swift     SwiftUI desktop app (single file): UI, Controller (process orchestration,
                           virtual display, local server), AppDelegate
app/CGVirtualDisplay.h     declarations of PRIVATE CoreGraphics API CGVirtualDisplay (bridging header)
app/TeslaDisplay.xcodeproj Xcode project for SwiftUI PREVIEW ONLY (target TeslaDisplayPreview, bundle id
                           local.tesla-screenshare.preview) — references the same TeslaDisplay.swift; the real
                           app is still built by scripts/build-app.sh. Preview = `ContentView_Previews` (#if DEBUG)
app/make-icon.swift        renders the app icon PNG at build time
scripts/build-app.sh       builds build/Tesla Display.app; downloads + checksum-verifies mediamtx & Caddy
                           into .cache/; ad-hoc codesigns. Env: UNIVERSAL=1 (arm64+x86_64 via lipo), VERSION.
                           App defaults are hardcoded: Route Direct Wi-Fi, Server https://screen.example.com
.github/workflows/release-app.yml  push branch release/<version> → universal build on macos-15 → tag
                           v<version> + GitHub Release (zip + SHA256SUMS); re-push = rebuild, moves tag,
                           --clobber assets. workflow_dispatch = artifacts only. No repo variables/secrets needed.
scripts/mac-capture.swift  ScreenCaptureKit capture → raw NV12 on stdout (+ optional f32le stereo audio to a FIFO)
scripts/mac-input-agent.swift  injects input via CGEvent. Modes: relay client (Home Server) or local
                           WebSocket server on 127.0.0.1 (Direct Wi-Fi, env LOCAL_LISTEN/LOCAL_PIN)
dev/mac-publish.sh         CLI equivalent of the app's publish pipeline (mac-capture | ffmpeg → WHIP)
dev/tesla-local-test.sh    serves a diagnostics page (http/https, WebRTC, WebGL, HW decode, screen size)
web/index.html             the viewer the Tesla loads (both routes). WHEP + WebSocket input + audio + gamepad
relay/relay.py             Home Server WebSocket relay (viewer ↔ Mac agent), Python websockets 13.1
Dockerfile, docker/entrypoint.sh  ONE image/container for the server: mediamtx + Caddy + relay, all on
                           127.0.0.1 inside; entrypoint prefixes logs ([caddy]/[mediamtx]/[relay]) and exits if
                           any service dies (compose restarts it). Env: DOMAIN, PUBLISH_TOKEN, CONTROL_PIN,
                           SITE_ADDRESS (Caddy site, default DOMAIN; ":80" = plain HTTP), MTX_WEBRTCADDITIONALHOSTS
docker-compose.yml Caddyfile mediamtx.yml .env.example   Home Server stack (single service `tesla-display`)
compose.behind-proxy.yml   override when an existing reverse proxy (user's nginx gateway) owns 80/443:
                           Caddy → plain HTTP on :8088 (PROXY_PORT); UDP 8189 still forwarded directly
nginx/                     example nginx sites: subdomain, and prefix path (/tesla/, strips prefix,
                           proxy_redirect / /tesla/) — the user's real setup is the PREFIX one
dev/compose.local.yml      override for testing the server stack on the Mac (Colima, HTTP :8088)
dev/LOCAL-TEST.md          how to test the server stack on the Mac
```
Generated / ignored (see `.gitignore`): `build/`, `.cache/`, `.bin/`, `.env`, `*.tgz`. `note.txt` is the user's — do not edit.

## Pipeline
```
mac-capture (SCK, NV12 @ fixed fps on stdout; audio → FIFO)
  → ffmpeg: libx264 zerolatency (-bf 0 -g 2*fps -sc_threshold 0, VBV bitrate/8) + libopus 128k → -f whip
  → mediamtx (NAS, or bundled on Mac at 127.0.0.1:8889) → WHEP → web/index.html <video>
input: viewer → WebSocket → (relay on NAS | agent's local WS server) → mac-input-agent → CGEvent
```
Display index = position in `CGGetActiveDisplayList` (same in mac-capture and mac-input-agent).

## Install / deploy
Repo: https://github.com/X-c0d3/tesla-display — both the Mac app and the server are installed with `git clone`
and updated with `git pull` (+ `./scripts/build-app.sh --install` on the Mac, `docker compose … up -d --build` on the
server). There is no tarball/scp step.

## Build / run / test
```bash
./scripts/build-app.sh            # app → build/Tesla Display.app (needs Xcode CLT, brew ffmpeg >= 8)
./scripts/build-app.sh --install  # + quit running app, copy to /Applications, reopen (user's normal flow)
swiftc -O scripts/mac-input-agent.swift -o /tmp/agent           # quick compile check of a tool
docker compose -f docker-compose.yml -f dev/compose.local.yml up -d --build   # server on the Mac (Colima, :8088)
docker compose up -d --build                                    # server on the NAS (no override!)
docker compose -f docker-compose.yml -f compose.behind-proxy.yml up -d --build  # NAS behind the user's nginx
```
Viewer JS syntax check: extract the `<script>` body of `web/index.html` and run `node --check`.
There is no unit-test suite; verify end to end:
- publish with `dev/mac-publish.sh <display>` (your process needs Screen Recording permission),
- open the viewer in a browser, then read `pc.getStats()` (inbound-rtp video fps/frames dropped, audio
  `totalAudioEnergy` while running `say …` on the Mac),
- for Direct Wi-Fi, run the bundled `mediamtx`, `caddy` and agent (`LOCAL_LISTEN=8766 LOCAL_PIN=…`) by hand
  from `build/Tesla Display.app/Contents/Resources` and probe with curl (whip from LAN must be 403,
  whep without PIN 401).
Don't post real input events while testing (pad/click messages move the user's real cursor/keys).

## Hard-won facts (don't re-learn these)
- **ffmpeg avfoundation screen capture is broken on macOS 26+/27** (hangs, no frames) → always ScreenCaptureKit.
- **Encoder is libx264 `-tune zerolatency` (NOT h264_videotoolbox).** VideoToolbox emits POC type 0 with no
  `max_num_reorder_frames`; with any packet loss mediamtx's DTS extractor mis-detects B-frames and closes every
  viewer ("WebRTC doesn't support H264 streams with B-frames") → viewer drop/reconnect loops. x264 zerolatency =
  POC type 2 / reorder 0. `-bufsize` = bitrate/8 caps keyframe bursts (they cost tens of ms on the uplink and
  Chrome sizes the jitter buffer for them; Colima/cellular also drop UDP bursts). Measured on a detailed 1920x1140
  still @8M/60: max keyframe 260 KB → 120 KB vs bitrate/2, first-frame SSIM 0.902 → 0.895, equal by frame 30.
  `-g 2*fps` (fewer keyframes; a new viewer waits ≤ 2 s) and `-sc_threshold 0` (no extra IDR on window switches).
- **mac-capture writes a frame as soon as SCK delivers one** (`onFrame` → out queue, `pending` flag so writes never
  queue up) and a timer repeats the last frame while the screen is still. Writes are paced so the frame COUNT tracks
  elapsed time × fps (event writes may run ≤ 1 frame ahead, the timer fills gaps) because ffmpeg derives pts from
  the count — unpaced event+timer writes showed 71 fps at a 60 fps setting.
  Cost: veryfast 1920x1200@30 ≈ 17x realtime, superfast @60 ≈ 13x on Apple Silicon.
- **Viewer must not leak RTCPeerConnections:** Chrome caps PCs per page (closed ones count until GC). The viewer
  retries WHEP when no publisher is live, so `closePc()` nulls handlers + `pc` and retries back off 2s → 15s.
  Never create a PC per retry without closing/backing off ("Cannot create so many PeerConnections").
- **Viewer splits audio and video out of one lip-sync group** (`unsyncAV()` rewrites the WHEP answer's `msid`).
  Video pts come from `-framerate` (frame count), audio pts from sample count; when the Mac delivers fewer frames
  than the fps setting, Chrome delays video to stay in sync with audio and the video jitter buffer grows without
  bound (measured 1.4 s on the car; reproduced locally with a 45 fps source declared as 60: 18 → 165 ms and rising,
  1–8 ms once split). Don't merge them back into one stream id.
- **ffmpeg's WHIP muxer only supports UDP ICE** and aborts if the first candidate is TCP → mediamtx has
  `webrtcLocalTCPAddress: ""`. Don't re-enable ICE-TCP.
- **No STUN** in mediamtx (`webrtcICEServers2: []`); it delayed answers ~5 s. Public address comes from
  `MTX_WEBRTCADDITIONALHOSTS` (= `DOMAIN`, or `COLIMA_IP` locally).
- **Audio timestamps:** do NOT use `-use_wallclock_as_timestamps` (audio came out silent). Let ffmpeg derive
  pts from `-framerate` / sample count. SCK delivers planar float32 (2 buffers) → interleave to f32le.
- **Virtual display:** new CGVirtualDisplay starts in a small mode (e.g. 960x600) → must force the 1x mode with
  `CGConfigureDisplayWithDisplayMode`. `sizeInMillimeters` is set for ~96 ppi. `maxPixels` is 3840x2400 so
  "Auto" can resize later via `apply(settings)`. Fixed `serialNum` so macOS remembers the arrangement.
- **TCC:** every rebuild is a new ad-hoc signature → macOS asks for Screen Recording/Accessibility again; after
  granting, the app must be **quit and reopened**. The app stops retrying when capture logs a TCC denial.
- **Tesla browser:** won't open raw-IP/plain-http on the internet route (needs a domain + HTTPS); must be parked
  (no video while driving); audio needs a user tap (autoplay policy); WebSockets drop often → viewer reconnects.
  Direct Wi-Fi is **on hold**: on the car (Juniper 2025, home Wi-Fi, same /24 as the Mac) both
  `https://192.168.137.166:8443` and `http://…:8080` gave ERR_CONNECTION_REFUSED while the Mac served them fine and
  saw no incoming connection → the car refuses before reaching the Mac (raw-IP URL, non-standard port, or LAN block —
  not narrowed down; self-signed cert never got tested). User does not want external DNS helpers (sslip.io/nip.io).
  Full screen without the URL bar works via Theater → YouTube → `youtube.com/redirect?q=<viewer URL>` (verified on
  Model Y Juniper 2025): viewport 1920x1140 @1x there vs 1922x1080 @1.53x in the normal browser.
  `/` auto-redirects every device through `youtube.com/redirect?q=<viewer>?fs=1` unless `?fs` is present (loop guard +
  60 s sessionStorage guard). Measured in Theater on the car: UA `Mozilla/5.0 (X11; Linux x86_64) … Chrome/148.0.0.0
  Safari/537.36 Tesla/2026.38.6 TESLA_AUTO_…_2025_TESLA_MODELY`; Extend + Auto gives size = view = 1920x1140,
  jitterbuf ~25 ms, decode ~6 ms, RTT ~33 ms (Home Server on Oracle, car on home Wi-Fi).
- **Colima** forwards only TCP unless started with `colima start --network-address` (address 192.168.64.2).
  The user's other container `acc-nginx` owns ports 443 and 8089 → local override uses 8088.
- macOS has no virtual-gamepad API without a restricted entitlement → gamepad is mapped to keyboard/mouse
  (mapping table in `mac-input-agent.swift`, documented in README).
- Caddy (Home Server) guards `/screen/whip` with `Authorization: Bearer <PUBLISH_TOKEN>` or `?token=`; WHEP is
  open (viewing needs no PIN on Home Server — known gap). Local Caddy blocks `/screen/whip*` (403) and requires
  `Authorization: Bearer <PIN>` for `/screen/*`.

## Conventions
- **All user-facing strings in English** (app UI, status, viewer page, CLI log lines). Code comments are Thai —
  keep that style for new comments. `README.md` / `dev/LOCAL-TEST.md` are Thai.
- Match the existing style: single-file Swift tools compiled with plain `swiftc` (no SPM; the only Xcode project is
  `app/TeslaDisplay.xcodeproj`, for previews — never make the release build depend on it);
  top-level code; avoid closures capturing top-level `guard let` locals (Swift error) — pass values in.
- The viewer and the Mac tools use RELATIVE / base-URL-joined paths (`screen/whep`, `input/viewer`,
  `<server>/screen/whip`, `<server>/input/agent`) so the stack works under a path prefix — keep it that way.
- Keep the server **docker-compose only**. The user explicitly does not want Cloudflare Tunnel/cloudflared or
  Proxmox/LXC setup scripts; they port-forward themselves.
- Pin image/binary versions (mediamtx v1.11.3, caddy 2.8.4, python:3.12-alpine + websockets 13.1).
  Verify checksums for downloads.
- `web/`, `relay/`, `Caddyfile`, `mediamtx.yml` are BAKED INTO the image → any change needs
  `docker compose … up -d --build` (no live-mounted files any more). Server update = `git pull` + rebuild.
- BusyBox userland in the image (python:3.12-alpine): no `sed -u`, no `wait -n` — keep entrypoint POSIX sh.
- After changing anything the app bundles (`app/`, `scripts/mac-*.swift`, `web/`), rebuild with
  `scripts/build-app.sh` and tell the user to recopy to `/Applications` and re-grant permissions.
- Don't run the server stack or long-lived processes on the user's Mac unless testing; clean up test processes.
- Never commit/print `.env` secrets.
