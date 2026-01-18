import asyncio
import json
import os
import time
from typing import Any, Dict, Optional

import logging

import httpx
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from starlette.websockets import WebSocketState

from lib.sonos_manager import SonosManager

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
SONOS_CFG = CONFIG.get("sonos", {})

SONOS_MANAGER = SonosManager(SONOS_CFG)

logger = logging.getLogger("events")
logging.basicConfig(level=logging.INFO)

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


async def fetch_settings(token: str) -> Dict[str, Any]:
    """Fetch dashboard settings for the authenticated user."""
    assert HTTP_CLIENT is not None
    try:
        resp = await HTTP_CLIENT.get(
            f"{API_BASE_URL}/api/settings",
            headers={"Authorization": f"Bearer {token}"},
        )
        if resp.status_code == 200:
            data = resp.json()
            if isinstance(data, dict) and "settings" in data:
                return data["settings"] or {}
    except httpx.HTTPError:
        return {}
    return {}


async def stream_now_playing(
    ws: WebSocket,
    token: str,
    stop_event: asyncio.Event,
    *,
    close_on_stop: bool = True,
    poll_interval_override: Optional[int] = None,
) -> None:
    assert HTTP_CLIENT is not None
    assert stop_event is not None
    poll_interval = poll_interval_override or SPOTIFY_CFG.get("pollIntervalSec", 5)
    retry_interval = SPOTIFY_CFG.get("retryIntervalSec", 2)
    retry_window = SPOTIFY_CFG.get("retryWindowSec", 20)
    cooldown = SPOTIFY_CFG.get("cooldownSec", 1800)

    etag: Optional[str] = None
    last_payload: Optional[Dict[str, Any]] = None
    failure_start: Optional[float] = None

    while not stop_event.is_set() and ws.application_state == WebSocketState.CONNECTED:
        try:
            headers = {"Authorization": f"Bearer {token}"}
            if etag:
                headers["If-None-Match"] = etag

            logger.debug("spotify: poll now-playing")
            resp = await HTTP_CLIENT.get(
                f"{API_BASE_URL}/api/spotify/now-playing",
                headers=headers,
            )

            if resp.status_code == 429:
                retry_after_header = resp.headers.get("Retry-After")
                retry_after = 30
                if retry_after_header:
                    try:
                        retry_after = int(retry_after_header)
                    except ValueError:
                        pass
                logger.warning(f"spotify: rate limited, backing off {retry_after}s")
                try:
                    await ws.send_json({"type": "error", "error": "spotify_rate_limited"})
                except Exception:
                    pass
                try:
                    await asyncio.wait_for(asyncio.sleep(retry_after), timeout=retry_after + 1)
                except asyncio.CancelledError:
                    break
                continue

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
                    logger.info("spotify: new now-playing payload")
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
            logger.info("spotify: stream cancelled")
            break
        except (httpx.TimeoutException, httpx.TransportError, httpx.HTTPStatusError):
            if stop_event.is_set():
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
            logger.info("spotify: websocket disconnect")
            break
        except Exception:
            # Unexpected failure: try to close gracefully
            try:
                await ws.send_json({"type": "error", "error": "internal_error"})
            finally:
                await _safe_close_ws(ws, code=1011)
            break

    if close_on_stop:
        await _safe_close_ws(ws, code=1000)
    logger.info("spotify: stream closed")


@app.websocket(WS_CFG.get("path", "/events/media"))
async def media_events(ws: WebSocket) -> None:
    token = ws.query_params.get("token")
    if not token:
        await _safe_close_ws(ws, code=4401, reason="Missing token")
        return

    user_info = await validate_token(token)
    if not user_info:
        await _safe_close_ws(ws, code=4401, reason="Invalid token")
        return

    settings = await fetch_settings(token)
    spotify_enabled = settings.get("spotify_enabled", True)
    sonos_enabled = settings.get("sonos_enabled", False)

    logger.info(f"ws connect user={user_info.get('payload',{}).get('sub')} spotify_enabled={spotify_enabled} sonos_enabled={sonos_enabled}")

    await ws.accept(subprotocol=None)
    await ws.send_json({"type": "ready", "user": user_info, "settings": settings})

    # Optional client config for poll intervals
    client_spotify_poll: Optional[int] = None
    client_sonos_poll: Optional[int] = None
    try:
        msg = await asyncio.wait_for(ws.receive_json(), timeout=2.0)
        if isinstance(msg, dict) and msg.get("type") == "config":
            poll_cfg = msg.get("poll") or {}
            sp = poll_cfg.get("spotify")
            so = poll_cfg.get("sonos")
            if isinstance(sp, (int, float)) and sp > 0:
                client_spotify_poll = int(sp)
            if isinstance(so, (int, float)) and so > 0:
                client_sonos_poll = int(so)
    except asyncio.TimeoutError:
        pass
    except Exception:
        pass

    connection_stop = asyncio.Event()
    sonos_task: Optional[asyncio.Task] = None
    spotify_task: Optional[asyncio.Task] = None

    # Prefer Sonos when enabled; if Sonos goes idle and Spotify is enabled, fall back automatically.
    if sonos_enabled:
        logger.info("starting sonos stream (primary)")
        sonos_task = asyncio.create_task(
            SONOS_MANAGER.stream(
                ws,
                connection_stop,
                stop_on_idle=spotify_enabled,
                poll_interval_override=client_sonos_poll,
            )
        )
        ACTIVE_TASKS.add(sonos_task)
    elif spotify_enabled:
        logger.info("starting spotify stream")
        spotify_task = asyncio.create_task(
            stream_now_playing(ws, token, connection_stop, poll_interval_override=client_spotify_poll)
        )
        ACTIVE_TASKS.add(spotify_task)

    try:
        while not connection_stop.is_set():
            if ws.application_state != WebSocketState.CONNECTED:
                logger.info("ws not connected; stopping media loop")
                break
            # If Sonos is enabled, run it as primary until it stops/pauses, then fall back to Spotify.
            if sonos_enabled:
                logger.info("starting sonos stream (primary loop)")
                sonos_task = asyncio.create_task(
                    SONOS_MANAGER.stream(
                        ws,
                        connection_stop,
                        stop_on_idle=spotify_enabled,
                        poll_interval_override=client_sonos_poll,
                    )
                )
                ACTIVE_TASKS.add(sonos_task)
                await asyncio.wait({sonos_task}, return_when=asyncio.FIRST_COMPLETED)
                ACTIVE_TASKS.discard(sonos_task)

                if ws.application_state != WebSocketState.CONNECTED:
                    logger.info("ws not connected after sonos stream; stopping media loop")
                    break

            # After Sonos stops/pauses, optionally fall back to Spotify
            if spotify_enabled and not connection_stop.is_set():
                if ws.application_state != WebSocketState.CONNECTED:
                    logger.info("ws not connected before spotify fallback; stopping media loop")
                    break
                logger.info("starting spotify stream (fallback loop)")
                spotify_task = asyncio.create_task(
                    stream_now_playing(
                        ws,
                        token,
                        connection_stop,
                        close_on_stop=False,
                        poll_interval_override=client_spotify_poll,
                    )
                )
                ACTIVE_TASKS.add(spotify_task)

                sonos_resume_task: Optional[asyncio.Task] = None
                if sonos_enabled:
                    sonos_resume_task = asyncio.create_task(SONOS_MANAGER.wait_for_playback(connection_stop))
                    ACTIVE_TASKS.add(sonos_resume_task)

                if sonos_resume_task:
                    done, pending = await asyncio.wait({spotify_task, sonos_resume_task}, return_when=asyncio.FIRST_COMPLETED)
                    resume_found = False
                    if sonos_resume_task in done:
                        try:
                            resume_found = bool(sonos_resume_task.result())
                        except Exception:
                            resume_found = False

                    if resume_found and not connection_stop.is_set() and ws.application_state == WebSocketState.CONNECTED:
                        logger.info("sonos: playback detected; switching from spotify to sonos")
                        spotify_task.cancel()
                        await asyncio.gather(spotify_task, return_exceptions=True)
                        ACTIVE_TASKS.discard(spotify_task)
                        for t in pending:
                            t.cancel()
                        await asyncio.gather(*pending, return_exceptions=True)
                        ACTIVE_TASKS.discard(sonos_resume_task)
                        # Loop back to start Sonos again
                        continue
                    else:
                        for t in pending:
                            t.cancel()
                        await asyncio.gather(*pending, return_exceptions=True)
                        if spotify_task in done:
                            await spotify_task
                        ACTIVE_TASKS.discard(sonos_resume_task)
                else:
                    await spotify_task

                ACTIVE_TASKS.discard(spotify_task)
            else:
                # No Spotify fallback configured; break to close
                break

            # If neither service is enabled, bail
            if not sonos_enabled and not spotify_enabled:
                await ws.send_json({"type": "error", "error": "no_services_enabled"})
                await _safe_close_ws(ws, code=1000, reason="No services enabled")
                break
    finally:
        connection_stop.set()
        for task in (sonos_task, spotify_task):
            if task:
                task.cancel()
        await asyncio.gather(*[t for t in (sonos_task, spotify_task) if t], return_exceptions=True)
        for task in (sonos_task, spotify_task):
            if task:
                ACTIVE_TASKS.discard(task)
        logger.info("ws connection closed")


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
