import asyncio
import json
import os
from typing import Any, Awaitable, Callable, Dict, Optional

import logging

import httpx
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from starlette.websockets import WebSocketState, WebSocketDisconnect

from lib.sonos_manager import SonosManager
from lib.spotify_manager import SpotifyManager

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
API_SSL_VERIFY = API_CFG.get("sslVerify", True)
SONOS_CFG = CONFIG.get("sonos", {})
SERVER_CFG = CONFIG.get("server", {})

SONOS_MANAGER = SonosManager(SONOS_CFG)
SPOTIFY_MANAGER = SpotifyManager(SPOTIFY_CFG, API_BASE_URL)

logger = logging.getLogger("events")
logging.basicConfig(level=logging.INFO)

HTTP_CLIENT: Optional[httpx.AsyncClient] = None
STOP_EVENT: Optional[asyncio.Event] = None
ACTIVE_TASKS: "set[asyncio.Task]" = set()
CONNECTION_STOPS: "set[asyncio.Event]" = set()


def _http_timeout() -> httpx.Timeout:
    t = SPOTIFY_CFG.get("requestTimeoutSec", 10)
    return httpx.Timeout(t, connect=t, read=t, write=t)

@asynccontextmanager
async def lifespan(app: FastAPI):
    global HTTP_CLIENT, STOP_EVENT, ACTIVE_TASKS, CONNECTION_STOPS
    STOP_EVENT = asyncio.Event()
    HTTP_CLIENT = httpx.AsyncClient(timeout=_http_timeout(), verify=API_SSL_VERIFY)
    try:
        yield
    finally:
        logger.info("lifespan: shutdown initiated; signalling STOP_EVENT")
        if STOP_EVENT:
            STOP_EVENT.set()
        logger.info("lifespan: signalling %d connection stop events", len(CONNECTION_STOPS))
        for evt in list(CONNECTION_STOPS):
            evt.set()
        logger.info("lifespan: cancelling %d active tasks", len(ACTIVE_TASKS))
        # cancel any active polling tasks, do not wait to avoid shutdown hangs
        for task in list(ACTIVE_TASKS):
            task.cancel()
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


async def _spotify_fallback_loop(
    *,
    ws: WebSocket,
    token: str,
    connection_stop: asyncio.Event,
    http_client: httpx.AsyncClient,
    poll_interval_override: Optional[int],
    sonos_enabled: bool,
    global_stop: Optional[asyncio.Event],
    safe_close: Callable[[WebSocket, int, str], Awaitable[None]],
) -> bool:
    """Run Spotify with retries; return True if Sonos playback is detected."""
    backoff = 1.0
    attempt = 0

    while not connection_stop.is_set() and ws.application_state == WebSocketState.CONNECTED:
        attempt += 1
        logger.info("spotify: attempt %d starting now-playing stream (backoff=%.1fs)", attempt, backoff)
        spotify_task = asyncio.create_task(
            SPOTIFY_MANAGER.stream_now_playing(
                ws=ws,
                token=token,
                stop_event=connection_stop,
                http_client=http_client,
                close_on_stop=False,
                poll_interval_override=poll_interval_override,
                safe_close=safe_close,
            )
        )
        ACTIVE_TASKS.add(spotify_task)

        sonos_resume_task: Optional[asyncio.Task] = None
        if sonos_enabled:
            sonos_resume_task = asyncio.create_task(
                SONOS_MANAGER.wait_for_playback(
                    connection_stop,
                    global_stop=global_stop,
                )
            )
            ACTIVE_TASKS.add(sonos_resume_task)

        wait_set = {spotify_task}
        if sonos_resume_task:
            wait_set.add(sonos_resume_task)

        try:
            done, pending = await asyncio.wait(wait_set, return_when=asyncio.FIRST_COMPLETED)
        except asyncio.CancelledError:
            connection_stop.set()
            for t in wait_set:
                t.cancel()
            await asyncio.gather(*wait_set, return_exceptions=True)
            ACTIVE_TASKS.difference_update(wait_set)
            return False

        # Sonos won; switch back to Sonos loop
        if sonos_resume_task and sonos_resume_task in done:
            logger.info("spotify: attempt %d ended because sonos resumed", attempt)
            for t in wait_set:
                t.cancel()
            await asyncio.gather(*wait_set, return_exceptions=True)
            ACTIVE_TASKS.difference_update(wait_set)
            return True

        # Spotify finished (likely API error). Retry with backoff if still connected
        if spotify_task in done:
            spotify_result = await asyncio.gather(spotify_task, return_exceptions=True)
            logger.warning(
                "spotify: attempt %d finished; connection_stop=%s ws_state=%s result=%s",
                attempt,
                connection_stop.is_set(),
                ws.application_state,
                spotify_result,
            )
            ACTIVE_TASKS.discard(spotify_task)
            if sonos_resume_task:
                sonos_resume_task.cancel()
                await asyncio.gather(sonos_resume_task, return_exceptions=True)
                ACTIVE_TASKS.discard(sonos_resume_task)

            if connection_stop.is_set() or ws.application_state != WebSocketState.CONNECTED:
                logger.info("spotify: stopping retries because connection_stop=%s ws_state=%s", connection_stop.is_set(), ws.application_state)
                return False

            logger.info("spotify: retrying after backoff=%.1fs", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 10.0)
            continue

    return False


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
    CONNECTION_STOPS.add(connection_stop)
    sonos_task: Optional[asyncio.Task] = None
    spotify_task: Optional[asyncio.Task] = None

    defer_sonos = False  # when true, skip sonos once to let spotify run

    try:
        while not connection_stop.is_set():
            logger.info(
                "media loop: start iteration ws_state=%s spotify_enabled=%s sonos_enabled=%s",
                ws.application_state,
                spotify_enabled,
                sonos_enabled,
            )
            if ws.application_state != WebSocketState.CONNECTED:
                logger.info("ws not connected; stopping media loop")
                break
            if STOP_EVENT and STOP_EVENT.is_set():
                logger.info("server stopping; ending media loop (connection_stop=%s)", connection_stop.is_set())
                connection_stop.set()
                break
            allow_sonos = sonos_enabled and not defer_sonos
            if allow_sonos:
                logger.info("starting sonos stream (primary loop)")
                sonos_task = asyncio.create_task(
                    SONOS_MANAGER.stream(
                        ws,
                        connection_stop,
                        stop_on_idle=spotify_enabled,
                        poll_interval_override=client_sonos_poll,
                        global_stop=STOP_EVENT,
                    )
                )
                ACTIVE_TASKS.add(sonos_task)
                try:
                    await asyncio.wait({sonos_task}, return_when=asyncio.FIRST_COMPLETED)
                except asyncio.CancelledError:
                    connection_stop.set()
                    sonos_task.cancel()
                    try:
                        await asyncio.wait_for(asyncio.gather(sonos_task, return_exceptions=True), timeout=1)
                    except asyncio.TimeoutError:
                        logger.info("shutdown: sonos task slow to cancel; skipping wait")
                    ACTIVE_TASKS.discard(sonos_task)
                    break
                ACTIVE_TASKS.discard(sonos_task)

                if ws.application_state != WebSocketState.CONNECTED:
                    logger.info("ws not connected after sonos stream; stopping media loop")
                    break

                # Sonos finished (likely idle). Defer Sonos once to allow Spotify to take over.
                defer_sonos = True
            else:
                if sonos_enabled and defer_sonos:
                    logger.info("skipping sonos this loop to allow spotify (deferred)")

            # After Sonos stops/pauses, optionally fall back to Spotify with retries
            if spotify_enabled and not connection_stop.is_set():
                if ws.application_state != WebSocketState.CONNECTED:
                    logger.info("ws not connected before spotify fallback; stopping media loop")
                    break
                logger.info("starting spotify stream (fallback loop)")
                assert HTTP_CLIENT is not None
                resume_found = await _spotify_fallback_loop(
                    ws=ws,
                    token=token,
                    connection_stop=connection_stop,
                    http_client=HTTP_CLIENT,
                    poll_interval_override=client_spotify_poll,
                    sonos_enabled=sonos_enabled,
                    global_stop=STOP_EVENT,
                    safe_close=_safe_close_ws,
                )
                if resume_found and not connection_stop.is_set() and ws.application_state == WebSocketState.CONNECTED:
                    logger.info("sonos: playback detected; switching from spotify to sonos")
                    defer_sonos = False
                    continue
                else:
                    # Either Spotify fully stopped or connection closed; if still connected, retry loop
                    if not connection_stop.is_set() and ws.application_state == WebSocketState.CONNECTED:
                        logger.info("spotify: fallback loop ended without sonos resume; retrying media loop and will re-enter sonos+spotify sequence")
                        defer_sonos = False
                        await asyncio.sleep(1)
                        continue
                    logger.info("spotify: fallback loop ended; stopping media loop")
                    break
            else:
                # No Spotify fallback configured; break to close
                break

            # If neither service is enabled, bail
            if not sonos_enabled and not spotify_enabled:
                await ws.send_json({"type": "error", "error": "no_services_enabled"})
                await _safe_close_ws(ws, code=1000, reason="No services enabled")
                break
    except asyncio.CancelledError:
        logger.info("media loop cancelled; stopping (connection_stop=%s)" % connection_stop.is_set())
        connection_stop.set()
    except WebSocketDisconnect:
        logger.info("ws disconnect; stopping media loop")
        connection_stop.set()
    finally:
        CONNECTION_STOPS.discard(connection_stop)
        logger.info(
            "media loop finally: cancelling tasks sonos=%s spotify=%s stop_event=%s ws_state=%s",
            bool(sonos_task),
            bool(spotify_task),
            connection_stop.is_set(),
            ws.application_state,
        )
        connection_stop.set()
        for task in (sonos_task, spotify_task):
            if task:
                task.cancel()
        for task in (sonos_task, spotify_task):
            if task:
                ACTIVE_TASKS.discard(task)
        # Ensure the websocket is closed so uvicorn shutdown does not hang waiting for open connections
        await _safe_close_ws(ws, code=1012, reason="Server shutting down")
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
        timeout_graceful_shutdown=SERVER_CFG.get("timeoutGracefulShutdownSec", 1),
        reload=False,
    )
