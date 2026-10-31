# Tesla Display

ใช้จอกลางของ Tesla เป็น**จอที่ 2 ของ MacBook** ผ่าน browser ของรถ สำหรับนั่งทำงานในรถตอนจอด

- **Extend** — Tesla เป็นจอที่ 2 จริง ลากหน้าต่างไปวางได้ (แอปสร้างจอเสมือนให้เอง) หรือ **Mirror** จอที่มีอยู่
- **แตะ / พิมพ์บนจอ Tesla** เพื่อควบคุม Mac (click, drag, scroll, คีย์บอร์ดไทย/อังกฤษ, คีย์ลัด)
- **เสียงจาก Mac ออกลำโพงรถ** และ **จอยเกมที่ต่อกับรถ** ใช้ควบคุม Mac ได้ (แปลงเป็นคีย์บอร์ด/เมาส์)
- **WebRTC + H.264 hardware** — ภาพลื่นกว่า Guacamole/VNC มาก
- **บน Tesla ไม่ต้องติดตั้งอะไร** แค่เปิด URL ใน browser
- 2 เส้นทาง: **Direct Wi-Fi** (ไม่ใช้ server) หรือ **Home Server** (ผ่าน NAS ที่บ้าน ใช้ได้ทุกที่)

---

## สารบัญ
1. [ทำงานยังไง](#ทำงานยังไง)
2. [สิ่งที่ต้องมี](#สิ่งที่ต้องมี)
3. [ติดตั้งแอปบน Mac](#1-ติดตั้งแอปบน-mac)
4. [หน้าแอป](#2-หน้าแอป)
5. [ใช้แบบ Direct Wi-Fi](#3-ใช้แบบ-direct-wi-fi-ไม่ใช้-server)
6. [ใช้แบบ Home Server](#4-ใช้แบบ-home-server-nas-ที่บ้าน)
7. [ควบคุมบน Tesla](#5-ควบคุมบน-tesla)
8. [ส่งจาก iPad](#6-ส่งจาก-ipad-ดูอย่างเดียว)
9. [ค่าที่แนะนำ](#7-ค่าที่แนะนำ)
10. [ความปลอดภัย](#8-ความปลอดภัย)
11. [แก้ปัญหา](#9-แก้ปัญหา)
12. [สำหรับนักพัฒนา](#10-สำหรับนักพัฒนา)

---

## ทำงานยังไง

**Direct Wi-Fi** — Tesla ต่อ Wi-Fi ของ Mac แล้วคุยกับ Mac ตรง (latency ต่ำสุด ไม่กินเน็ตมือถือเรื่องภาพ)
```
            Wi-Fi ของ Mac (Internet Sharing)
Tesla browser ──https://192.168.2.1:8443──► Mac: Caddy (หน้าเว็บ) + mediamtx (ภาพ) + agent (แตะ/พิมพ์)
              ◄══════ WebRTC ภาพ ═════════
```

**Home Server** — ภาพวิ่งผ่าน NAS ที่บ้าน (Mac กับรถอยู่คนละที่ได้)
```
Mac ──WHIP──► NAS: Caddy + mediamtx + input relay ──WHEP──► Tesla browser
Mac ◄──WS (แตะ/พิมพ์)────────────────────────────────WS──── Tesla browser
```
Mac เป็นฝ่ายต่อออกไปหา NAS เอง จึงไม่ต้องเปิดพอร์ตฝั่ง Mac / hotspot

---

## สิ่งที่ต้องมี
| | Direct Wi-Fi | Home Server |
|---|---|---|
| Mac | macOS 15+, Apple Silicon หรือ Intel | เหมือนกัน |
| ffmpeg | `brew install ffmpeg` (เวอร์ชัน 8 ขึ้นไป) | เหมือนกัน |
| Xcode Command Line Tools | สำหรับ build แอป (`xcode-select --install`) | เหมือนกัน |
| เน็ต | Mac ต้องมีเน็ตจาก iPhone (USB) หรือ Ethernet เพื่อแชร์ Wi-Fi ให้รถ | Mac และรถต้องออกเน็ตได้ |
| Server | ไม่ต้องมี | NAS/เครื่องที่รัน Docker + โดเมน + port-forward |

---

## 1. ติดตั้งแอปบน Mac

```bash
./scripts/build-app.sh --install
```
คำสั่งเดียว: ปิดแอปเดิม → compile → คัดลอกไป `/Applications` → เปิดแอป
(ครั้งแรกจะดาวน์โหลด mediamtx / Caddy พร้อมตรวจ checksum มาใส่ในแอปให้เอง)
แก้โค้ดเมื่อไหร่ก็รันคำสั่งเดิมซ้ำได้เลย — ถ้าอยาก build อย่างเดียวไม่ติดตั้ง ใช้ `./scripts/build-app.sh`

**ให้สิทธิ์ครั้งแรก** (System Settings > Privacy & Security):
1. **Screen & System Audio Recording** → เปิด *Tesla Display*
2. **Accessibility** → เปิด *Tesla Display* (สำหรับรับการแตะ/พิมพ์จากรถ)
3. **Quit แล้วเปิดแอปใหม่** — macOS ใช้สิทธิ์ใหม่หลังเปิดแอปใหม่เท่านั้น
4. โหมด Direct Wi-Fi: ครั้งแรก macOS อาจถามให้ *caddy* / *mediamtx* รับการเชื่อมต่อขาเข้า → **Allow**

> build แอปใหม่ทุกครั้ง macOS จะมองเป็นแอปใหม่ (ad-hoc signature) — ถ้าส่งภาพไม่ได้หลัง build
> ให้ลบ *Tesla Display* ออกจากรายการสิทธิ์ทั้งสองด้วยปุ่ม **−** แล้วเพิ่มใหม่ด้วย **+**

---

## 2. หน้าแอป

### Display
| ตัวเลือก | ความหมาย |
|---|---|
| **Mode: Extend** | สร้างจอเสมือนชื่อ *Tesla Display* — Tesla เป็นจอที่ 2 ลากหน้าต่างไปวางได้ |
| **Mode: Mirror** | ส่งภาพจอที่มีอยู่ (เลือกจอใน *Screen*) — Tesla แสดงเหมือนจอนั้น |
| **Resolution: Auto** (ค่าเริ่มต้น) | เริ่มที่ 1920x1200 แล้วปรับให้ตรงจอ Tesla อัตโนมัติเมื่อรถเปิดหน้าเว็บ (แสดงขนาดที่วัดได้ใต้ตัวเลือก) |
| **Resolution: More workspace** | 2304x1440 – 3840x2400 พื้นที่ทำงานมากขึ้น ตัวหนังสือเล็กลง |
| **Resolution: Larger text** | 1680x1050 – 1280x800 ตัวหนังสือใหญ่ขึ้น |
| **FPS** | 30 (แนะนำสำหรับทำงาน) / 60 |
| **Bitrate** | เพดานความเร็วภาพ 2–20 Mbps (ดู [ค่าที่แนะนำ](#7-ค่าที่แนะนำ)) |
| **Log** (แถบล่าง) | เปิด/ปิดแผง Log ที่เลื่อนออกทางขวา — สีแดง = error, ส้ม = กำลังต่อใหม่; copy / clear ได้ |

สลับ **Extend / Mirror ได้ระหว่างใช้งาน** แอปจะเริ่มใหม่ให้เอง (ภาพบนรถหายไป ~1–2 วินาที)
ภาพที่ส่งไปรถถูกจำกัดไว้ไม่เกิน 1920x1200 แม้จอเสมือนจะใหญ่กว่า (ประหยัด bitrate)

### Connection
| ตัวเลือก | ความหมาย |
|---|---|
| **Route: Direct Wi-Fi** | Mac เป็น server เอง ไม่ใช้ server ข้างนอก — ใช้ **PIN** (สุ่มให้, copy ได้, กด 🎲 สุ่มใหม่) |
| **Route: Home Server** | ส่งผ่าน NAS — ใส่ **Server** (`https://<โดเมน>`) และ **Token** (`PUBLISH_TOKEN`, กด 👁 เพื่อดู) |
| **Touch / keyboard / gamepad control from Tesla** | ปิดถ้าต้องการให้รถดูอย่างเดียว |
| **Send Mac audio to Tesla** | ส่งเสียงระบบของ Mac (Opus 128 kbps) ไปออกลำโพงรถ |

### Open on Tesla (เฉพาะ Direct Wi-Fi)
แสดง URL ที่ต้องพิมพ์บนรถสำหรับแต่ละวง network ของ Mac พร้อมปุ่ม copy และ PIN
(Internet Sharing จะเป็น `https://192.168.2.1:8443` เสมอ)

### แถบล่าง
- **สถานะ** — เทา = Stopped, เขียว (เต้น) = Live, ส้ม = กำลังต่อใหม่
- **ตัวนับเวลา** มุมขวาบน — เวลาที่รันไปแล้วตั้งแต่กด Start
- **Start / Stop**, **Log** (ดูข้อความจาก ffmpeg / agent / server), **Quit** (หยุดทุกอย่างแล้วปิดแอป)

แอปต่อใหม่เองทุก 3 วินาทีเมื่อเน็ตหลุด และจำค่าทั้งหมดไว้ (เปิดครั้งหน้าไม่ต้องตั้งใหม่)

---

## 3. ใช้แบบ Direct Wi-Fi (ไม่ใช้ server)

1. **Mac → System Settings > General > Sharing > Internet Sharing**
   - *Share your connection from*: **iPhone USB** (หรือ Ethernet)
   - *To devices using*: **Wi-Fi** → ตั้งชื่อ/รหัส Wi-Fi แล้วเปิด
   - (Mac แชร์ Wi-Fi ต่อจาก Wi-Fi ด้วยกันไม่ได้)
2. **Tesla → Controls > Wi-Fi** → ต่อ Wi-Fi ของ Mac
3. **แอป** → Route **Direct Wi-Fi** → กด **Start**
4. **Tesla browser** → เปิด URL จากการ์ด *Open on Tesla* (ปกติ `https://192.168.2.1:8443`)
   - ครั้งแรกขึ้นหน้าเตือนใบรับรอง → **Advanced → Proceed**
   - ถ้า Tesla ไม่ยอมเปิด https แบบ self-signed ให้ลอง `http://192.168.2.1:8080`
5. ใส่ **PIN** → มุมซ้ายบนขึ้น `live (direct)`

> ทางเลือก: Mac และ Tesla ต่อ hotspot มือถือเครื่องเดียวกัน (ใช้ URL ของวงนั้นจากการ์ด *Open on Tesla*)
> hotspot ต้องไม่กั้นเครื่องในวงคุยกันเอง

---

## 4. ใช้แบบ Home Server (NAS ที่บ้าน)

### 4.1 ติดตั้ง server (Docker บน NAS / Proxmox LXC)
server เป็น **container เดียว** (`tesla-display`: mediamtx + Caddy + input relay ใน image เดียว)
ไฟล์ที่ต้องใช้บน server (`scripts/package-server.sh` แพ็กให้ครบ):
`Dockerfile` `docker/` `docker-compose.yml` `compose.behind-proxy.yml` `Caddyfile` `mediamtx.yml` `.env.example` `relay/` `web/` `nginx/`

> ที่บ้านมี nginx เป็น gateway อยู่แล้ว / ต้องการใช้ prefix path → ทำข้อ 4.1 จนถึง `nano .env` แล้วข้ามไป [4.2.1](#421-ใช้-nginx-เดิมเป็น-gateway--prefix-path-เช่น-httpshomeexamplecomtesla)

```bash
# บน Mac: แพ็กแล้วคัดลอกขึ้น server
./scripts/package-server.sh
scp build/tesla-screenshare-server.tgz root@<SERVER-IP>:/opt/
```
```bash
# บน server
mkdir -p /opt/tesla-screenshare && cd /opt/tesla-screenshare
tar -xzf ../tesla-screenshare-server.tgz && cp .env.example .env
sed -i.bak "s/^PUBLISH_TOKEN=.*/PUBLISH_TOKEN=$(openssl rand -hex 24)/" .env && rm .env.bak
nano .env          # ใส่ DOMAIN และ CONTROL_PIN
docker compose up -d --build
docker compose logs -f         # รอบรรทัด [caddy] … "certificate obtained"
```

| ค่าใน `.env` | ใส่อะไร |
|---|---|
| `DOMAIN` | โดเมนที่ชี้มา IP บ้าน เช่น `xxx.duckdns.org` (ไม่ต้องมี `https://`) |
| `PUBLISH_TOKEN` | สุ่มด้วยคำสั่ง `sed` ข้างบน — ใส่ค่าเดียวกันในช่อง Token ของแอป |
| `CONTROL_PIN` | PIN ที่พิมพ์บน Tesla (อย่างน้อย 6 ตัว ยิ่งยาวยิ่งดี) |

Proxmox LXC ต้องเปิด `nesting=1,keyctl=1`

### 4.2 เครือข่าย
| อะไร | ตั้งค่า |
|---|---|
| DNS | A record ของ `DOMAIN` → IP บ้าน (DDNS ถ้า IP เปลี่ยน; Cloudflare ให้ปิด proxy = เมฆสีเทา) |
| Port-forward router → IP ของ server | **TCP 80** (ขอใบรับรอง), **TCP 443** (เว็บ / WHIP / WHEP / input), **UDP 8189** (ภาพ) |

- Tesla browser ไม่ยอมเปิด raw IP ต้องใช้โดเมน
- เน็ตบ้านแบบ CGNAT (port-forward ไม่ได้) ใช้โหมดนี้ไม่ได้ → ใช้ Direct Wi-Fi แทน
- IP บ้านเปลี่ยนหลัง DDNS อัปเดต → `docker compose restart`

### 4.2.1 ใช้ nginx เดิมเป็น gateway + prefix path (เช่น `https://home.example.com/tesla/`)
ใช้เมื่อที่บ้านมี nginx ถือพอร์ต 80/443 อยู่แล้ว และโดเมนหลักมีเว็บอื่นใช้งานอยู่ — ระบบนี้จะอยู่ใต้ path `/tesla/`
โดยไม่แตะเว็บหลัก

```
Tesla / Mac ──https://home.example.com/tesla/──► nginx (เดิม, ถือใบรับรอง) ──http──► <LXC>:8088 (Caddy ของเรา) ──► mediamtx / relay
Tesla / Mac ◄════════════ UDP 8189 (ภาพ+เสียง WebRTC, ไม่ผ่าน nginx) ═══════════════► <LXC>:8189 (mediamtx)
```
nginx ส่งต่อแค่หน้าเว็บ, signalling (WHIP/WHEP) และ WebSocket (แตะ/พิมพ์/จอย) — ภาพไม่ผ่าน nginx จึงไม่ทำให้ช้าลง

#### ขั้นที่ 1 — `.env` บน server
```bash
DOMAIN=home.example.com     # โดเมนเดียวกับที่ nginx ใช้ — ไม่ต้องใส่ https:// และไม่ต้องใส่ /tesla
PUBLISH_TOKEN=…             # สุ่มตามข้อ 4.1
CONTROL_PIN=…               # แนะนำ 10 ตัวขึ้นไป
# PROXY_PORT=8088           # (ไม่บังคับ) พอร์ต HTTP ที่ nginx จะส่งต่อมา
```

#### ขั้นที่ 2 — รัน stack แบบอยู่หลัง reverse proxy
```bash
cd /opt/tesla-screenshare
docker compose -f docker-compose.yml -f compose.behind-proxy.yml up -d --build
docker compose -f docker-compose.yml -f compose.behind-proxy.yml ps    # ต้องเห็น tesla-display … Up
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8088/          # ต้องได้ 200
```
`compose.behind-proxy.yml` ทำให้ Caddy ของเราเป็น HTTP ธรรมดาบนพอร์ต 8088 (ไม่ขอใบรับรอง ไม่แย่งพอร์ต 80/443 ของ nginx)
ทุกครั้งที่สั่ง docker compose บน server นี้ต้องใส่ `-f docker-compose.yml -f compose.behind-proxy.yml`

#### ขั้นที่ 3 — เพิ่ม location ใน nginx
ตัวอย่างเต็มอยู่ที่ [nginx/tesla-display-prefix.conf](nginx/tesla-display-prefix.conf)

**3.1** ระดับ `http { }` (เช่นไฟล์ใน `conf.d/`) — ข้ามได้ถ้า config หลักมี `map $http_upgrade` อยู่แล้ว (ประกาศซ้ำจะ error):
```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

**3.2** ใน `server { }` เดิมของ `home.example.com` (บล็อก `listen 443 ssl`) เพิ่ม:
```nginx
location = /tesla {
    return 301 /tesla/;
}

location /tesla/ {
    proxy_pass http://192.168.1.50:8088/;       # IP ของ LXC ที่รัน docker : PROXY_PORT  ("/" ท้าย = ตัด /tesla ออก)
    proxy_redirect / /tesla/;                   # เติม /tesla กลับใน header Location
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Prefix /tesla;
    proxy_set_header Upgrade $http_upgrade;     # WebSocket (แตะ/พิมพ์/จอย)
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 1h;                      # ไม่ตัด WebSocket เมื่อไม่ได้แตะจอนาน
    proxy_send_timeout 1h;
    proxy_buffering off;
    client_max_body_size 1m;
}
```
- แก้ `192.168.1.50` เป็น IP ของ LXC — ถ้า nginx รันใน docker ห้ามใช้ `localhost`/`127.0.0.1` (จะหมายถึง container ของ nginx เอง)
- อยากใช้ชื่ออื่นแทน `/tesla` ต้องแก้ให้ตรงกันทั้ง 4 ที่: `location = /tesla`, `return 301`, `location /tesla/`, `proxy_redirect`

**3.3** ตรวจและโหลด config ใหม่:
```bash
nginx -t && nginx -s reload
# nginx ใน docker: docker exec <container> nginx -t && docker exec <container> nginx -s reload
```

#### ขั้นที่ 4 — router / firewall
| พอร์ต | ไปที่ | หมายเหตุ |
|---|---|---|
| TCP 80, 443 | nginx (เหมือนเดิม) | ไม่ต้องเปลี่ยนอะไร |
| **UDP 8189** | **IP ของ LXC** ที่รัน docker | **ต้องเพิ่ม** — พอร์ตภายนอก = ภายใน = 8189 |
| TCP 8088 | — | **ห้ามเปิดออก internet** ให้เฉพาะ nginx เข้าถึง (เป็น HTTP ธรรมดา) |

Proxmox firewall / `ufw` ใน LXC: อนุญาต UDP 8189 จากทุกที่ และ TCP 8088 จาก IP ของ nginx เท่านั้น

#### ขั้นที่ 5 — ตรวจสอบ (จากเครื่องนอกบ้าน เช่นมือถือปิด Wi-Fi)
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://home.example.com/tesla/          # 200
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://home.example.com/tesla/screen/whip   # 401 (ไม่มี token = ถูกต้อง)
curl -si -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGVzdA==" https://home.example.com/tesla/input/viewer | head -1   # HTTP/1.1 101 Switching Protocols
```

#### ขั้นที่ 6 — ใช้งาน
| | ใส่อะไร |
|---|---|
| แอปบน Mac → Route **Home Server** → Server | `https://home.example.com/tesla` |
| Token | `PUBLISH_TOKEN` |
| Tesla browser | `https://home.example.com/tesla/` (แนะนำ bookmark) |
| iPad / Larix (WHIP) | `https://home.example.com/tesla/screen/whip?token=<PUBLISH_TOKEN>` |

#### แก้ปัญหาแบบ nginx + prefix
| อาการ | สาเหตุ / วิธีแก้ |
|---|---|
| `nginx -t`: `duplicate "connection_upgrade" variable` | มี `map` อยู่แล้ว → ลบบล็อก 3.1 ออก |
| `/tesla/` ได้ 502 Bad Gateway | nginx ไปไม่ถึง `<LXC>:8088` — เช็ก IP, `docker compose … ps`, firewall TCP 8088 |
| หน้าเว็บขึ้นแต่แตะ/พิมพ์ไม่ได้, ขั้นที่ 5 ไม่ได้ 101 | ขาด `proxy_http_version 1.1` / `Upgrade` / `Connection` หรือ `map` |
| แตะได้แต่ค้างที่ `waiting for video…` | UDP 8189 ไม่ถึง LXC หรือ `DOMAIN` ไม่ได้ชี้ IP บ้าน |
| แอปบน Mac ขึ้น `Disconnected (exit …)` วน | Server ในแอปต้องมี `/tesla` (ไม่มี `/` ท้ายก็ได้) และ Token ตรงกับ `.env` |
| เปิด `https://home.example.com/tesla` แล้วไปหน้าเว็บหลัก | ขาด `location = /tesla { return 301 /tesla/; }` |

> ถ้ามี subdomain แยกให้ระบบนี้ (เช่น `screen.example.com`) ใช้ [nginx/tesla-display.conf](nginx/tesla-display.conf)
> แทนได้ — ขั้นตอนเหมือนกัน แค่ไม่มี `/tesla`

### 4.3 ใช้งาน
1. แอป → Route **Home Server** → Server `https://<DOMAIN>` (หรือ `https://<DOMAIN>/tesla` ถ้าใช้ prefix), Token = `PUBLISH_TOKEN` → **Start**
2. Tesla browser → `https://<DOMAIN>` (หรือ `…/tesla/`) → ใส่ `CONTROL_PIN` (หรือ *View only* เพื่อดูอย่างเดียว)

---

## 5. ควบคุมบน Tesla
**ต้องจอดรถ (เกียร์ P)** — Tesla ไม่เล่นวิดีโอใน browser ระหว่างขับ

| ท่าทาง / ปุ่ม | บน Mac |
|---|---|
| แตะ | click (แตะสองครั้งเร็วๆ = double click) |
| แตะค้าง ~0.5 วินาที | right click |
| แตะแล้วลาก**ทันที** | drag / เลือกข้อความ |
| สองนิ้วเลื่อน | scroll |
| ⌨ | เปิด/ปิดคีย์บอร์ดของ Tesla (พิมพ์ไทย/อังกฤษได้) |
| ⌘ ⌥ ⌃ ⇧ | modifier ใช้ครั้งเดียว เช่น ⌘ แล้วพิมพ์ `c` = Cmd+C |
| esc ⇥ | Escape, Tab |
| ⛶ | fullscreen |
| 🔊 / 🔇 | เปิด/ปิดเสียง (แตะจอครั้งแรกจะเปิดเสียงให้อัตโนมัติ — browser บล็อกเสียงจนกว่าจะแตะ) |

### จอยเกม
ต่อจอย USB / Bluetooth เข้ากับรถ หน้าเว็บจะขึ้น `🎮 … connected` แล้วส่งปุ่มไปที่ Mac
macOS ไม่ยอมให้แอปสร้าง "จอยเสมือน" จึงแปลงเป็นคีย์บอร์ด/เมาส์ (ใช้กับเกมที่เล่นด้วยคีย์บอร์ด+เมาส์ได้
แต่เกมที่ต้องใช้จอยจริงจะไม่เห็นจอยนี้)

| จอย | Mac |
|---|---|
| อนาล็อกซ้าย | W A S D |
| อนาล็อกขวา | เลื่อนเมาส์ |
| D-pad | ลูกศร |
| A / B / X / Y | Space / Esc / E / Q |
| LB / RB | Shift / R |
| LT / RT | คลิกขวา / คลิกซ้าย |
| Back / Start | Tab / Return |

Tesla จำ PIN ไว้ในรถ ครั้งต่อไปเปิด URL เดิมได้เลย (แนะนำ bookmark)

---

## 6. ส่งจาก iPad (ดูอย่างเดียว)
ใช้ได้กับ **Home Server** เท่านั้น — iPadOS ไม่ให้แอปอื่นสั่งแตะ/พิมพ์แทนผู้ใช้
1. ติดตั้ง **Larix Screencaster** (App Store; ฟรีครั้งละ 5 นาที, Premium ไม่จำกัด)
2. เพิ่ม connection แบบ **WebRTC (WHIP)**: `https://<DOMAIN>/screen/whip?token=<PUBLISH_TOKEN>`
   (ถ้ามีช่อง Bearer token ให้ตัด `?token=…` แล้วใส่ token ในช่องนั้น) — H.264, 30 fps, 4–6 Mbps, keyframe 1 วินาที
3. Control Center → กดค้าง **Screen Recording** → เลือก Larix → Start Broadcast
4. Tesla เปิด `https://<DOMAIN>` → *View only* (ส่งได้ทีละเครื่อง เครื่องที่ส่งทีหลังจะแทนที่)

---

## 7. ค่าที่แนะนำ
| สัญญาณ / เส้นทาง | FPS | Bitrate |
|---|---|---|
| Direct Wi-Fi | 30 | 8–10 Mbps |
| Home Server + 5G แรง | 30 | 6–8 Mbps |
| Home Server + 4G ปกติ | 30 | 4–5 Mbps |
| Home Server + สัญญาณอ่อน | 30 | 2–3 Mbps + Resolution 1280x800 |

ปริมาณเน็ต (Home Server, ใช้เต็มเพดาน): 3 Mbps ≈ 1.3 GB/ชม., 5 Mbps ≈ 2.2 GB/ชม., 8 Mbps ≈ 3.6 GB/ชม.
(หน้าจอนิ่งใช้น้อยกว่านี้มาก; ถ้า Mac และรถใช้ hotspot เดียวกันให้คิด ×2)

---

## 8. ความปลอดภัย
**Direct Wi-Fi**
- ต้องใส่ PIN ทั้งดูภาพและควบคุม (ใส่ผิดหน่วง 2 วินาที)
- คนในวงเดียวกันส่งภาพปลอมเข้ามาไม่ได้ (`/screen/whip` ปิดจากภายนอก และ API ของ mediamtx ฟังเฉพาะ 127.0.0.1)
- ใบรับรองเป็น self-signed — ใช้ในวง Wi-Fi ของ Mac เอง

**Home Server**
- ส่งภาพเข้า server ต้องมี `PUBLISH_TOKEN` (Caddy ตรวจ `Authorization: Bearer` หรือ `?token=`)
- ควบคุม Mac ต้องใช้ `CONTROL_PIN` — **ใช้ PIN ยาวๆ** ใครได้ PIN ไปก็ควบคุม Mac ได้
- ⚠️ **การดูภาพยังไม่ต้องใช้ PIN** และโดเมนถูกค้นเจอได้จาก Certificate Transparency log
  → ใช้เฉพาะตอนจำเป็น / ปิด port-forward เมื่อไม่ใช้ / หรือเปลี่ยน path `screen` เป็นสตริงสุ่ม
  ใน `mediamtx.yml`, `Caddyfile`, `web/index.html`

ทั้งสองแบบ: กด **Stop** เมื่อไม่ใช้งาน — หลัง Stop ไม่มีใครควบคุม Mac ได้

---

## 9. แก้ปัญหา
| อาการ | สาเหตุ / วิธีแก้ |
|---|---|
| macOS ถามสิทธิ์ Screen Recording ซ้ำๆ | สิทธิ์ผูกกับ build เก่า → ลบ *Tesla Display* ด้วย **−** แล้วเพิ่มใหม่, **Quit แล้วเปิดแอปใหม่** |
| สถานะ `No Screen Recording permission…` | เหมือนข้อบน |
| แตะบนรถแล้ว Mac ไม่ตอบสนอง | ยังไม่ได้ให้สิทธิ์ Accessibility หรือปิดสวิตช์ *Touch / keyboard control* |
| `Could not create virtual display` | ใช้ Mode **Mirror** แทน (API จอเสมือนอาจเปลี่ยนหลังอัปเดต macOS) |
| `ffmpeg not found` | `brew install ffmpeg` |
| Tesla ขึ้น `Enter the PIN to view` / `wrong PIN` | ใส่ PIN ให้ตรงกับในแอป (Direct) หรือ `CONTROL_PIN` (Home Server) |
| ไม่มีเสียงบนรถ | แตะจอ 1 ครั้ง หรือกด 🔇 → 🔊; เช็กว่าเปิด *Send Mac audio to Tesla* และเสียง Mac ไม่ได้ mute |
| จอยไม่ทำงาน | กดปุ่มบนจอย 1 ครั้งให้ browser เห็น (ขึ้น `🎮 connected`); ต้องใส่ PIN (View only ส่งจอยไม่ได้) |
| Tesla ค้างที่ `waiting for video…` | รถไปไม่ถึง UDP ของ Mac/server: เช็ก Wi-Fi วงเดียวกัน, macOS Firewall (Direct) หรือ UDP 8189 port-forward (Home Server) |
| Tesla ขึ้น `WHEP 404` | Mac ยังไม่ได้ส่งภาพ (กด Start / ดู Log) |
| `Disconnected (exit …) — retrying` วนไปเรื่อยๆ (Home Server) | Server URL/Token ผิด หรือ server ไม่ทำงาน — ดู Log และ `docker compose logs` |
| `Mac offline` บนรถ (Home Server) | แอปไม่ได้ Start หรือ Token ไม่ตรงกับ `PUBLISH_TOKEN` |
| ใบรับรอง HTTPS ไม่ออก (Home Server) | ตรวจ TCP 80/443 forward และ DNS ชี้ IP บ้าน (`docker compose logs | grep caddy`) |

---

## 10. สำหรับนักพัฒนา

### โครงสร้าง
```
app/                    แอป macOS (SwiftUI) + header ของ private API จอเสมือน
scripts/
  build-app.sh          build "Tesla Display.app" (+ ดาวน์โหลด mediamtx / Caddy)
  mac-capture.swift     จับภาพจอด้วย ScreenCaptureKit → raw NV12 ออก stdout
  mac-input-agent.swift รับแตะ/พิมพ์ (ต่อ relay หรือเปิด WebSocket ในเครื่องสำหรับ Direct Wi-Fi)
  package-server.sh     แพ็กไฟล์ server → build/tesla-screenshare-server.tgz
web/index.html          หน้า viewer บน Tesla (ใช้ทั้งสองโหมด)
relay/relay.py          input relay (Python) สำหรับ Home Server
Dockerfile  docker/entrypoint.sh       image เดียวของ server (mediamtx + Caddy + relay)
docker-compose.yml  compose.behind-proxy.yml  Caddyfile  mediamtx.yml  .env.example   ฝั่ง server
nginx/                  ตัวอย่าง config nginx (subdomain / prefix path)
dev/                    เครื่องมือสำหรับนักพัฒนา (ผู้ใช้ทั่วไปไม่ต้องสนใจ)
  LOCAL-TEST.md  compose.local.yml   ทดสอบ server บน Mac (Colima)
  mac-publish.sh        ส่งภาพแบบ command line (mac-capture | ffmpeg → WHIP)
  tesla-local-test.sh   ทดสอบว่า Tesla browser เปิดหน้าจาก Mac ในวง Wi-Fi ได้แบบไหน
```

### ทดสอบ server บน Mac ก่อน deploy
ดู [dev/LOCAL-TEST.md](dev/LOCAL-TEST.md) (Colima ต้อง `colima start --network-address`)

### ใช้แบบ command line (ไม่ใช้แอป)
```bash
./dev/mac-publish.sh list
SCREEN_URL=https://<DOMAIN> TOKEN=<PUBLISH_TOKEN> ./dev/mac-publish.sh 1
swiftc -O scripts/mac-input-agent.swift -o .bin/mac-input-agent
SCREEN_URL=https://<DOMAIN> TOKEN=<PUBLISH_TOKEN> ./.bin/mac-input-agent 1
```
ตัวเลือกของ `dev/mac-publish.sh`: `FPS=30 BITRATE=8M SIZE=1920x1200` (`SIZE=` ว่าง = ขนาดเดิม) `AUDIO=1` (`AUDIO=0` = ภาพอย่างเดียว)
Terminal ต้องมีสิทธิ์ Screen Recording และ Accessibility
