#!/usr/bin/env python3
"""WebSocket MITM proxy: logs all messages between Vibing and the real server."""
import asyncio
import json
import ssl
import websockets

REAL_SERVER = "wss://vibing-api-ccegdhbrg2d6bsd7.b02.azurefd.net/ws/pipeline"

def fmt(msg):
    if isinstance(msg, str):
        try:
            return json.dumps(json.loads(msg), indent=2, ensure_ascii=False)
        except json.JSONDecodeError:
            return msg[:500]
    return f"(binary {len(msg)} bytes)"

async def handler(client_ws):
    # Forward query string to real server
    path = client_ws.request.path or ""
    target = REAL_SERVER + ("?" + path.split("?", 1)[1] if "?" in path else "")
    print(f"\n{'='*60}", flush=True)
    print(f"Client connected, proxying to: {target}", flush=True)

    ssl_ctx = ssl.create_default_context()
    async with websockets.connect(target, ssl=ssl_ctx) as server_ws:
        async def client_to_server():
            try:
                async for msg in client_ws:
                    tag = "TEXT" if isinstance(msg, str) else "BIN"
                    print(f"\n>>> CLIENT [{tag}]:\n{fmt(msg)}", flush=True)
                    await server_ws.send(msg)
            except websockets.ConnectionClosed:
                pass

        async def server_to_client():
            try:
                async for msg in server_ws:
                    tag = "TEXT" if isinstance(msg, str) else "BIN"
                    print(f"\n<<< SERVER [{tag}]:\n{fmt(msg)}", flush=True)
                    await client_ws.send(msg)
            except websockets.ConnectionClosed:
                pass

        await asyncio.gather(client_to_server(), server_to_client())
    print(f"\n{'='*60}\nConnection closed\n", flush=True)

async def main():
    print("MITM proxy: ws://127.0.0.1:9999 -> real server", flush=True)
    async with websockets.serve(handler, "127.0.0.1", 9999):
        await asyncio.Future()

asyncio.run(main())
