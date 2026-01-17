import asyncio
import json
import os
import time
from typing import Any, Dict, Optional

import httpx
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from starlette.websockets import WebSocketState

load_dotenv()

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(BASE_DIR, os.pardir))
ENV = os.getenv("ENV", "dev")
CONFIG_PATH = os.path.join(BASE_DIR, "conf", f"{ENV}.json")

with open(CONFIG_PATH, "r", encoding="utf-8") as f:
    CONFIG = json.load(f)

SPOTIFY_CFG = CONFIG.get("spotify", {})
WS_CFG = CONFIG.get("websocket", {})
API_CFG = CONFIG.get("api", {})
API_BASE_URL = API_CFG.get("baseUrl", "http://localhost:5001")

HTTP_CLIENT: Optional[httpx.AsyncClient] = None


def _http_timeout() -> httpx.Timeout:
    t = SPOTIFY_CFG.get("requestTimeoutSec", 10)
    return httpx.Timeout(t, connect=t, read=t, write=t)

@asynccontextmanager
async def lifespan(app: FastAPI):
    global HTTP_CLIENT
    HTTP_CLIENT = httpx.AsyncClient(timeout=_http_timeout())
    try:
        yield
    finally:
        if HTTP_CLIENT:
            await HTTP_CLIENT.aclose()
            HTTP_CLIENT = None


app = FastAPI(title="Media Display Events Service", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"]
)


async def validate_token(token: str) -> Optional[Dict[str, Any]]:
    if not token:
        return None
    assert HTTP_CLIENT is not None
    try:
        resp = await HTTP_CLIENT.get(
            f"{API_BASE_URL}/api/auth/validate",
            headers={"Authorization": f"Bearer {token}"},
        )
        if resp.status_code == 200:
            return resp.json()
    except httpx.HTTPError:
        return None
    return None


async def stream_now_playing(ws: WebSocket, token: str) -> None:
    assert HTTP_CLIENT is not None
    poll_interval = SPOTIFY_CFG.get("pollIntervalSec", 5)
    retry_interval = SPOTIFY_CFG.get("retryIntervalSec", 2)
    retry_window = SPOTIFY_CFG.get("retryWindowSec", 20)
    cooldown = SPOTIFY_CFG.get("cooldownSec", 1800)

    etag: Optional[str] = None
    last_payload: Optional[Dict[str, Any]] = None
    failure_start: Optional[float] = None

    while ws.application_state == WebSocketState.CONNECTED:
        try:
            headers = {"Authorization": f"Bearer {token}"}
            if etag:
                headers["If-None-Match"] = etag

            resp = await HTTP_CLIENT.get(
                f"{API_BASE_URL}/api/spotify/now-playing",
                headers=headers,
            )

            if resp.status_code == 304:
                failure_start = None
            elif resp.status_code == 401:
                await ws.close(code=4401, reason="Unauthorized")
                break
            elif resp.status_code >= 500:
                resp.raise_for_status()
            else:
                payload = resp.json()
                etag = resp.headers.get("ETag", etag)
                if payload != last_payload:
                    await ws.send_json({
                        "type": "now_playing",
                        "data": payload,
                    })
                    last_payload = payload
                failure_start = None

            await asyncio.sleep(poll_interval)
            continue

        except (httpx.TimeoutException, httpx.TransportError, httpx.HTTPStatusError):
            now = time.monotonic()
            failure_start = failure_start or now
            elapsed = now - failure_start
            if elapsed >= retry_window:
                await asyncio.sleep(cooldown)
                failure_start = None
            else:
                await asyncio.sleep(retry_interval)
            continue
        except WebSocketDisconnect:
            break
        except Exception:
            # Unexpected failure: try to close gracefully
            try:
                await ws.send_json({"type": "error", "error": "internal_error"})
            finally:
                await ws.close(code=1011)
            break


@app.websocket(WS_CFG.get("path", "/events/spotify"))
async def spotify_events(ws: WebSocket) -> None:
    token = ws.query_params.get("token")
    if not token:
        await ws.close(code=4401, reason="Missing token")
        return

    user_info = await validate_token(token)
    if not user_info:
        await ws.close(code=4401, reason="Invalid token")
        return

    await ws.accept(subprotocol=None)
    await ws.send_json({"type": "ready", "user": user_info})
    await stream_now_playing(ws, token)


if __name__ == "__main__":
    import uvicorn

    def resolve_path(path: Optional[str]) -> Optional[str]:
        if not path:
            return None
        if os.path.isabs(path):
            return path
        return os.path.join(PROJECT_ROOT, path)

    uvicorn.run(
        "app:app",
        host=WS_CFG.get("host", "0.0.0.0"),
        port=WS_CFG.get("port", 5002),
        ssl_certfile=resolve_path(WS_CFG.get("sslCertFile")),
        ssl_keyfile=resolve_path(WS_CFG.get("sslKeyFile")),
        reload=False,
    )
