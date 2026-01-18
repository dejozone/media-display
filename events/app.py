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
STOP_EVENT: Optional[asyncio.Event] = None
ACTIVE_TASKS: "set[asyncio.Task]" = set()


def _http_timeout() -> httpx.Timeout:
    t = SPOTIFY_CFG.get("requestTimeoutSec", 10)
    return httpx.Timeout(t, connect=t, read=t, write=t)

@asynccontextmanager
async def lifespan(app: FastAPI):
    global HTTP_CLIENT, STOP_EVENT, ACTIVE_TASKS
    STOP_EVENT = asyncio.Event()
    HTTP_CLIENT = httpx.AsyncClient(timeout=_http_timeout())
    try:
        yield
    finally:
        if STOP_EVENT:
            STOP_EVENT.set()
        # cancel any active polling tasks
        for task in list(ACTIVE_TASKS):
            task.cancel()
        # wait for tasks to finish quietly
        if ACTIVE_TASKS:
            await asyncio.gather(*ACTIVE_TASKS, return_exceptions=True)
        ACTIVE_TASKS.clear()
        if HTTP_CLIENT:
            await HTTP_CLIENT.aclose()
            HTTP_CLIENT = None


async def _safe_close_ws(ws: WebSocket, code: int, reason: str = "") -> None:
    try:
        if ws.application_state == WebSocketState.CONNECTED:
            await ws.close(code=code, reason=reason)
    except Exception:
        pass


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
    assert STOP_EVENT is not None
    poll_interval = SPOTIFY_CFG.get("pollIntervalSec", 5)
    retry_interval = SPOTIFY_CFG.get("retryIntervalSec", 2)
    retry_window = SPOTIFY_CFG.get("retryWindowSec", 20)
    cooldown = SPOTIFY_CFG.get("cooldownSec", 1800)

    etag: Optional[str] = None
    last_payload: Optional[Dict[str, Any]] = None
    failure_start: Optional[float] = None

    while not STOP_EVENT.is_set() and ws.application_state == WebSocketState.CONNECTED:
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
                await _safe_close_ws(ws, code=4401, reason="Unauthorized")
                break
            elif resp.status_code >= 500:
                resp.raise_for_status()
            else:
                payload = resp.json()
                etag = resp.headers.get("ETag", etag)
                if payload != last_payload:
                    await ws.send_json({
                        "type": "now_playing",
                        "provider": "spotify",
                        "data": payload,
                    })
                    last_payload = payload
                failure_start = None

            await asyncio.wait_for(asyncio.sleep(poll_interval), timeout=poll_interval + 1)
            continue

        except asyncio.CancelledError:
            break
        except (httpx.TimeoutException, httpx.TransportError, httpx.HTTPStatusError):
            if STOP_EVENT.is_set():
                break
            now = time.monotonic()
            failure_start = failure_start or now
            elapsed = now - failure_start
            if elapsed >= retry_window:
                try:
                    await asyncio.wait_for(asyncio.sleep(cooldown), timeout=cooldown + 1)
                except asyncio.CancelledError:
                    break
                failure_start = None
            else:
                try:
                    await asyncio.wait_for(asyncio.sleep(retry_interval), timeout=retry_interval + 1)
                except asyncio.CancelledError:
                    break
            continue
        except WebSocketDisconnect:
            break
        except Exception:
            # Unexpected failure: try to close gracefully
            try:
                await ws.send_json({"type": "error", "error": "internal_error"})
            finally:
                await _safe_close_ws(ws, code=1011)
            break

    await _safe_close_ws(ws, code=1000)


@app.websocket(WS_CFG.get("path", "/events/media"))
async def spotify_events(ws: WebSocket) -> None:
    token = ws.query_params.get("token")
    if not token:
        await _safe_close_ws(ws, code=4401, reason="Missing token")
        return

    user_info = await validate_token(token)
    if not user_info:
        await _safe_close_ws(ws, code=4401, reason="Invalid token")
        return

    await ws.accept(subprotocol=None)
    await ws.send_json({"type": "ready", "user": user_info})

    # run stream as task so we can track/cancel on shutdown
    stream_task = asyncio.create_task(stream_now_playing(ws, token))
    ACTIVE_TASKS.add(stream_task)
    try:
        await stream_task
    finally:
        ACTIVE_TASKS.discard(stream_task)


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
