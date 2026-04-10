#!/usr/bin/env python3
"""MITM proxy for Vibing: handles both WebSocket and HTTP on port 443."""
import asyncio
import json
import ssl
import datetime
import os
import socket as _socket
import websockets

REAL_HOST = "vibing-api-ccegdhbrg2d6bsd7.b02.azurefd.net"
REAL_SERVER_IP = "13.107.226.59"
CERT_DIR = "/tmp/vibing_spy/certs"
LOG_DIR = "/tmp/vibing_spy"
LISTEN_PORT = 443
WS_PORT = 9998  # internal, plain WS

# Bypass /etc/hosts for our own outbound connections
_orig_getaddrinfo = _socket.getaddrinfo
def _patched_getaddrinfo(host, port, *args, **kwargs):
    if host == REAL_HOST:
        return _orig_getaddrinfo(REAL_SERVER_IP, port, *args, **kwargs)
    return _orig_getaddrinfo(host, port, *args, **kwargs)
_socket.getaddrinfo = _patched_getaddrinfo

LOG_FILE = None

def init_log():
    global LOG_FILE
    os.makedirs(LOG_DIR, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    path = os.path.join(LOG_DIR, f"vibing_{ts}.log")
    LOG_FILE = open(path, "a", encoding="utf-8")
    log(f"Log file: {path}")

def log(text):
    ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{ts}] {text}"
    print(line, flush=True)
    if LOG_FILE:
        LOG_FILE.write(line + "\n")
        LOG_FILE.flush()

def fmt(msg):
    if isinstance(msg, str):
        try:
            return json.dumps(json.loads(msg), indent=2, ensure_ascii=False)
        except json.JSONDecodeError:
            return msg[:500]
    return f"(binary {len(msg)} bytes)"

# ── Bidirectional TCP pipe ──
async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError, OSError):
        pass
    finally:
        try:
            if not writer.is_closing():
                writer.close()
        except Exception:
            pass

# ── TLS front-door: route GET→WS, everything else→HTTP proxy ──
async def tls_router(client_r, client_w):
    try:
        first_line = await asyncio.wait_for(client_r.readline(), timeout=10)
    except Exception:
        client_w.close()
        return
    if not first_line:
        client_w.close()
        return

    method = first_line.split(b" ", 1)[0]

    if method == b"GET":
        # Forward to internal plain WebSocket server
        try:
            srv_r, srv_w = await asyncio.open_connection("127.0.0.1", WS_PORT)
        except Exception as e:
            log(f"Internal WS connect failed: {e}")
            client_w.close()
            return
        srv_w.write(first_line)
        await srv_w.drain()
        await asyncio.gather(pipe(client_r, srv_w), pipe(srv_r, client_w))
    else:
        # HTTP request → proxy to real server, log request & response
        try:
            await proxy_http(first_line, client_r, client_w)
        except (ConnectionError, asyncio.IncompleteReadError, OSError) as e:
            log(f"HTTP proxy error (non-fatal): {e}")

async def proxy_http(first_line, client_r, client_w):
    method_path = first_line.decode(errors="replace").strip()
    log(f"\n>>> CLIENT [HTTP]: {method_path}")

    # Read remaining headers
    headers_raw = first_line
    content_length = 0
    while True:
        line = await client_r.readline()
        headers_raw += line
        low = line.lower()
        if low.startswith(b"content-length:"):
            content_length = int(line.split(b":")[1].strip())
        if line == b"\r\n":
            break

    # Read body
    body = b""
    if content_length > 0:
        body = await client_r.readexactly(content_length)

    # Log body
    if body:
        try:
            txt = body.decode("utf-8")
            try:
                log(json.dumps(json.loads(txt), indent=2, ensure_ascii=False))
            except json.JSONDecodeError:
                log(txt[:3000])
        except UnicodeDecodeError:
            log(f"(binary body {len(body)} bytes)")

    # Connect to real server
    try:
        up_ssl = ssl.create_default_context()
        srv_r, srv_w = await asyncio.open_connection(
            REAL_SERVER_IP, 443, ssl=up_ssl, server_hostname=REAL_HOST
        )
    except Exception as e:
        log(f"Upstream connect failed: {e}")
        client_w.close()
        return

    # Forward request
    srv_w.write(headers_raw + body)
    await srv_w.drain()

    # Read response headers
    resp_headers = b""
    resp_cl = 0
    chunked = False
    while True:
        line = await srv_r.readline()
        resp_headers += line
        low = line.lower()
        if low.startswith(b"content-length:"):
            resp_cl = int(line.split(b":")[1].strip())
        if b"transfer-encoding" in low and b"chunked" in low:
            chunked = True
        if line == b"\r\n":
            break

    # Read response body
    resp_body = b""
    if chunked:
        while True:
            size_line = await srv_r.readline()
            resp_body += size_line
            size = int(size_line.strip(), 16)
            if size == 0:
                trailing = await srv_r.readline()
                resp_body += trailing
                break
            chunk = await srv_r.readexactly(size)
            resp_body += chunk
            crlf = await srv_r.readline()
            resp_body += crlf
    elif resp_cl > 0:
        resp_body = await srv_r.readexactly(resp_cl)

    # Log response
    status_line = resp_headers.split(b"\r\n", 1)[0].decode(errors="replace")
    log(f"\n<<< SERVER [HTTP]: {status_line}")
    if resp_body:
        # For chunked, extract just the data
        raw = resp_body
        if chunked:
            # Reassemble chunked body for logging
            pieces, buf = [], resp_body
            while buf:
                idx = buf.find(b"\r\n")
                sz = int(buf[:idx], 16)
                if sz == 0:
                    break
                pieces.append(buf[idx+2:idx+2+sz])
                buf = buf[idx+2+sz+2:]
            raw = b"".join(pieces)
        try:
            txt = raw.decode("utf-8")
            try:
                log(json.dumps(json.loads(txt), indent=2, ensure_ascii=False))
            except json.JSONDecodeError:
                log(txt[:3000])
        except UnicodeDecodeError:
            log(f"(binary response {len(raw)} bytes)")

    # Forward response to client
    client_w.write(resp_headers + resp_body)
    await client_w.drain()

    srv_w.close()
    client_w.close()

# ── WebSocket handler (on internal plain port) ──
async def ws_handler(client_ws):
    path = client_ws.request.path or ""
    qs = "?" + path.split("?", 1)[1] if "?" in path else ""
    target = f"wss://{REAL_HOST}/ws/pipeline{qs}"
    log(f"\n{'='*60}")
    log(f"WS connected, proxying to: {target}")

    ssl_ctx = ssl.create_default_context()
    async with websockets.connect(target, ssl=ssl_ctx) as server_ws:
        async def c2s():
            try:
                async for msg in client_ws:
                    tag = "TEXT" if isinstance(msg, str) else "BIN"
                    log(f"\n>>> CLIENT [WS {tag}]:\n{fmt(msg)}")
                    await server_ws.send(msg)
            except websockets.ConnectionClosed:
                pass

        async def s2c():
            try:
                async for msg in server_ws:
                    tag = "TEXT" if isinstance(msg, str) else "BIN"
                    log(f"\n<<< SERVER [WS {tag}]:\n{fmt(msg)}")
                    await client_ws.send(msg)
            except websockets.ConnectionClosed:
                pass

        await asyncio.gather(c2s(), s2c())
    log(f"\n{'='*60}\nWS closed\n")

# ── Main ──
async def main():
    init_log()

    # 1) Internal plain WebSocket server
    await websockets.serve(ws_handler, "127.0.0.1", WS_PORT)
    log(f"Internal WS on :{WS_PORT}")

    # 2) TLS front-door router
    tls_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_ctx.load_cert_chain(
        os.path.join(CERT_DIR, "cert.pem"),
        os.path.join(CERT_DIR, "key.pem"),
    )
    await asyncio.start_server(tls_router, "127.0.0.1", LISTEN_PORT, ssl=tls_ctx)
    log(f"TLS router on :{LISTEN_PORT}  (WS→:{WS_PORT}, HTTP→{REAL_HOST})")

    await asyncio.Future()

asyncio.run(main())
