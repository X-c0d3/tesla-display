# Pairing server (Direct Wi-Fi): ที่นัดเจอระหว่าง Tesla กับ Mac — ส่งต่อแค่ข้อความเล็กๆ ไม่รับภาพ
#   GET /            หน้า viewer (web/index.html โหมด pair) — Tesla เปิดหน้านี้ผ่าน domain จริง + HTTPS จริง
#   /input/agent     Mac agent, ข้อความแรก {"auth": PIN}  -> เปิดห้องชื่อ PIN
#   /input/viewer    Tesla page, ข้อความแรก {"auth": PIN} -> เข้าห้องเดียวกัน
# ใน Wi-Fi วงเดียวกัน: viewer ส่ง WebRTC offer ผ่านห้อง -> agent ถาม mediamtx บน Mac -> answer กลับมา
# แล้วภาพ/เสียงวิ่งตรง Mac -> Tesla ทาง UDP (ไม่ผ่าน server นี้); touch/keyboard ยังส่งผ่านห้อง
import asyncio
import hmac
import json
import os
import time

from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Response

WEB = os.environ.get("WEB_DIR", "/srv")
LISTEN = os.environ.get("PAIR_LISTEN", "0.0.0.0")
PORT = int(os.environ.get("PAIR_PORT", "8090"))
MIN_PIN = 6
MAX_ROOMS = 2000
# กันเดา PIN: เข้าห้องที่ไม่มี Mac ออนไลน์ได้ไม่เกิน FAIL_MAX ครั้งต่อ FAIL_WINDOW วินาทีต่อ IP
FAIL_MAX = 30
FAIL_WINDOW = 600

with open(os.path.join(WEB, "index.html"), "rb") as f:
    PAGE = f.read().replace(b'<html lang="en">', b'<html lang="en" data-mode="pair">', 1)

rooms = {}  # pin -> {"agent": ws | None, "key": กุญแจของ Mac เจ้าของห้อง, "viewers": set()}
fails = {}  # ip -> [เวลาที่เข้าห้องว่าง]


def client_ip(ws):
    # อยู่หลัง nginx: IP จริงคือตัวท้ายของ X-Forwarded-For
    fwd = ws.request.headers.get("X-Forwarded-For", "")
    if fwd:
        return fwd.split(",")[-1].strip()
    return ws.remote_address[0] if ws.remote_address else "?"


def too_many_fails(ip):
    now = time.monotonic()
    if len(fails) > 10000:  # ล้าง IP เก่าๆ ไม่ให้กินหน่วยความจำ
        for k in [k for k, v in fails.items() if not v or now - v[-1] >= FAIL_WINDOW]:
            del fails[k]
    recent = [t for t in fails.get(ip, []) if now - t < FAIL_WINDOW]
    fails[ip] = recent
    return len(recent) >= FAIL_MAX


def room(pin):
    r = rooms.get(pin)
    if r is None:
        r = rooms[pin] = {"agent": None, "key": "", "viewers": set()}
    return r


def cleanup(pin):
    r = rooms.get(pin)
    if r and r["agent"] is None and not r["viewers"]:
        del rooms[pin]


def status(r, t="agent"):
    return json.dumps({"t": t, "online": r["agent"] is not None, "mode": "direct"})


async def broadcast(r, msg):
    for v in list(r["viewers"]):
        try:
            await v.send(msg)
        except Exception:
            pass


async def handle_agent(ws, pin, key):
    r = room(pin)
    if r["agent"] is not None:
        if not hmac.compare_digest(r["key"], key):
            # Mac เครื่องอื่นได้ PIN ซ้ำ -> ไม่ให้แย่งห้อง (แอปจะบอกให้สุ่ม PIN ใหม่)
            await ws.send('{"t":"inuse"}')
            return
    # Mac เดิมต่อใหม่ (เช่นเน็ตหลุด) -> ใช้ตัวใหม่; ตั้งตัวใหม่ก่อนปิดตัวเก่า
    # (ระหว่างรอปิด ตัวเก่าจะเก็บกวาดห้อง — ถ้ายังเป็นตัวเก่าอยู่ห้องจะถูกลบทิ้ง)
    old, r["agent"], r["key"] = r["agent"], ws, key
    if old is not None:
        await old.close()
    print(f"agent online ({len(rooms)} rooms)", flush=True)
    try:
        await ws.send('{"t":"ok"}')
        await broadcast(r, status(r))
        async for msg in ws:  # answer ของ WebRTC -> ทุก viewer ในห้อง (viewer เลือกเองจาก id)
            if isinstance(msg, str):
                await broadcast(r, msg)
    except ConnectionClosed:
        pass  # เน็ตหลุด/ปิดแอปกลางคัน — ไม่ต้องพิมพ์ traceback
    finally:
        if r["agent"] is ws:
            r["agent"] = None
            r["key"] = ""
            await broadcast(r, status(r))
        cleanup(pin)


async def handle_viewer(ws, pin):
    r = room(pin)
    r["viewers"].add(ws)
    try:
        await ws.send(status(r, "ok"))
        async for msg in ws:
            if r["agent"] is not None and isinstance(msg, str):
                try:
                    await r["agent"].send(msg)
                except Exception:
                    pass
    except ConnectionClosed:
        pass
    finally:
        r["viewers"].discard(ws)
        cleanup(pin)


async def handler(ws):
    is_agent = ws.request.path.startswith("/input/agent")
    try:
        first = json.loads(await asyncio.wait_for(ws.recv(), 10))
        pin = str(first.get("auth", ""))
        key = str(first.get("key", ""))
    except Exception:
        return
    if len(pin) < MIN_PIN or len(pin) > 64:
        await asyncio.sleep(2)
        await ws.send('{"t":"denied"}')
        return
    if is_agent:
        if pin not in rooms and len(rooms) >= MAX_ROOMS:
            await ws.send('{"t":"busy"}')
            return
        if len(key) < 32:
            await ws.send('{"t":"denied"}')
            return
        return await handle_agent(ws, pin, key)
    # viewer: ห้องที่ไม่มี Mac = นับเป็นการเดา (Mac ออฟไลน์ชั่วคราวก็นับ แต่ไม่ถึงเพดานในการใช้งานปกติ)
    if rooms.get(pin, {}).get("agent") is None:
        ip = client_ip(ws)
        if too_many_fails(ip):
            await asyncio.sleep(2)
            await ws.send('{"t":"busy"}')
            return
        fails[ip].append(time.monotonic())
        if pin not in rooms and len(rooms) >= MAX_ROOMS:
            await ws.send('{"t":"busy"}')
            return
    await handle_viewer(ws, pin)


def http(connection, request):
    # ไม่ใช่ WebSocket -> เสิร์ฟหน้า viewer
    if request.path.startswith("/input/"):
        return None
    path = request.path.split("?", 1)[0]
    if path not in ("/", "/index.html"):
        return Response(404, "Not Found", Headers([("Content-Length", "0")]), b"")
    return Response(200, "OK", Headers([
        ("Content-Type", "text/html; charset=utf-8"),
        ("Cache-Control", "no-store"),
        ("Content-Length", str(len(PAGE))),
    ]), PAGE)


async def main():
    async with serve(handler, LISTEN, PORT, process_request=http, max_size=65536, ping_interval=20):
        print(f"pair server on {LISTEN}:{PORT}", flush=True)
        await asyncio.Future()


asyncio.run(main())
