# Input relay (Home Server): Tesla viewer (touch/keyboard/gamepad) -> WebSocket -> Mac input agent
#   /input/agent   Mac agent, first message {"auth": PUBLISH_TOKEN}
#   /input/viewer  Tesla page, first message {"auth": CONTROL_PIN}
import asyncio
import hmac
import json
import os

from websockets.asyncio.server import serve

TOKEN = os.environ["PUBLISH_TOKEN"]
PIN = os.environ["CONTROL_PIN"]
if len(PIN) < 6:
    raise SystemExit("CONTROL_PIN must be at least 6 characters")

agent = None
viewers = set()


def agent_status(t="agent"):
    return json.dumps({"t": t, "online": agent is not None, "mode": "server"})


async def broadcast(msg):
    for v in list(viewers):
        try:
            await v.send(msg)
        except Exception:
            pass


async def handle_agent(ws):
    global agent
    if agent is not None:
        await agent.close()
    agent = ws
    print("agent connected", flush=True)
    try:
        await ws.send('{"t":"ok"}')
        await broadcast(agent_status())
        async for _ in ws:
            pass
    finally:
        if agent is ws:
            agent = None
            print("agent disconnected", flush=True)
            await broadcast(agent_status())


async def handle_viewer(ws):
    viewers.add(ws)
    try:
        await ws.send(agent_status("ok"))
        async for msg in ws:
            if agent is not None and isinstance(msg, str):
                try:
                    await agent.send(msg)
                except Exception:
                    pass
    finally:
        viewers.discard(ws)


async def handler(ws):
    is_agent = ws.request.path.startswith("/input/agent")
    try:
        first = json.loads(await asyncio.wait_for(ws.recv(), 10))
        auth = str(first.get("auth", ""))
    except Exception:
        return
    if not hmac.compare_digest(auth, TOKEN if is_agent else PIN):
        await asyncio.sleep(2)  # slow down PIN guessing
        await ws.send('{"t":"denied"}')
        return
    await (handle_agent(ws) if is_agent else handle_viewer(ws))


async def main():
    async with serve(handler, "127.0.0.1", 8765, max_size=65536, ping_interval=20):
        await asyncio.Future()


asyncio.run(main())
