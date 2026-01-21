import asyncio
import contextlib
import json
import logging
import os
from typing import Any, Awaitable, Callable, Dict, Optional, Set

import httpx
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from starlette.websockets import WebSocketState

from lib.sonos_manager import SonosManager
from lib.spotify_manager import SpotifyManager, SupportsWebSocket

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
ACTIVE_TASKS: Set[asyncio.Task] = set()


class MultiSessionChannel:
    """Fan-out channel for all sessions of a single user."""

    def __init__(self, user_id: str):
        self.user_id = user_id
        self.sessions: Dict[str, WebSocket] = {}
        self._lock = asyncio.Lock()

    @property
    def application_state(self) -> WebSocketState:
        for ws in list(self.sessions.values()):
            try:
                if ws.application_state == WebSocketState.CONNECTED:
                    return WebSocketState.CONNECTED
            except Exception:
                continue
        return WebSocketState.DISCONNECTED

    def has_sessions(self) -> bool:
        return any(True for _ in self.sessions.values())

    async def add(self, session_id: str, ws: WebSocket) -> None:
        async with self._lock:
            self.sessions[session_id] = ws

    async def remove(self, session_id: str) -> None:
        async with self._lock:
            self.sessions.pop(session_id, None)

    async def send_json(self, data: Any, mode: str = "text") -> None:
        stale: Set[str] = set()
        for sid, ws in list(self.sessions.items()):
            try:
                if ws.application_state == WebSocketState.CONNECTED:
                    await ws.send_json(data, mode=mode)
                else:
                    stale.add(sid)
            except Exception:
                stale.add(sid)
        for sid in stale:
            await self.remove(sid)

    async def close(self, code: int = 1000, reason: str = "") -> None:
        for sid, ws in list(self.sessions.items()):
            try:
                if ws.application_state == WebSocketState.CONNECTED:
                    await ws.close(code=code, reason=reason)
            except Exception:
                pass
        self.sessions.clear()


class UserContext:
    def __init__(self, user_id: str, token: str):
        self.user_id = user_id
        self.token = token
        self.channel = MultiSessionChannel(user_id)
        self.stop_event = asyncio.Event()
        self.service_stop_event = asyncio.Event()
        self.driver_task: Optional[asyncio.Task] = None
        self.config: Dict[str, Any] = {
            "enabled": {"spotify": False, "sonos": False},
            "poll": {"spotify": None, "sonos": None},
        }
        self.config_event = asyncio.Event()
        self.lock = asyncio.Lock()

    def enabled_any(self) -> bool:
        en = self.config.get("enabled", {})
        return bool(en.get("spotify") or en.get("sonos"))


USER_CONTEXTS: Dict[str, UserContext] = {}


def _http_timeout() -> httpx.Timeout:
    t = SPOTIFY_CFG.get("requestTimeoutSec", 10)
    return httpx.Timeout(t, connect=t, read=t, write=t)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global HTTP_CLIENT, STOP_EVENT, ACTIVE_TASKS
    STOP_EVENT = asyncio.Event()
    HTTP_CLIENT = httpx.AsyncClient(timeout=_http_timeout(), verify=API_SSL_VERIFY)
    try:
        yield
    finally:
        logger.info("lifespan: shutdown initiated; cancelling tasks")
        if STOP_EVENT:
            STOP_EVENT.set()
        for ctx in list(USER_CONTEXTS.values()):
            ctx.stop_event.set()
            await ctx.channel.close(code=1012, reason="Server shutting down")
        USER_CONTEXTS.clear()
        for task in list(ACTIVE_TASKS):
            task.cancel()
        ACTIVE_TASKS.clear()
        if HTTP_CLIENT:
            await HTTP_CLIENT.aclose()
            HTTP_CLIENT = None


async def _safe_close_ws(ws: SupportsWebSocket, code: int, reason: str = "") -> None:
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
    allow_headers=["*"],
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
    """Deprecated: Settings are expected from the client via websocket config."""
    return {}


async def _spotify_fallback_loop(
    *,
    channel: MultiSessionChannel,
    token: str,
    connection_stop: asyncio.Event,
    http_client: httpx.AsyncClient,
    poll_interval_override: Optional[int],
    sonos_enabled: bool,
    global_stop: Optional[asyncio.Event],
    safe_close: Callable[[SupportsWebSocket, int, str], Awaitable[None]],
) -> bool:
    """Run Spotify stream with retry/backoff until stopped or Sonos resumes."""

    backoff = 1.0
    attempt = 0

    while not connection_stop.is_set() and channel.application_state == WebSocketState.CONNECTED:
        attempt += 1
        logger.info(
            "spotify: attempt %d starting now-playing stream (backoff=%.1fs)", attempt, backoff
        )
        spotify_task = asyncio.create_task(
            SPOTIFY_MANAGER.stream_now_playing(
                ws=channel,
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
            done, _ = await asyncio.wait(wait_set, return_when=asyncio.FIRST_COMPLETED)
        except asyncio.CancelledError:
            connection_stop.set()
            for t in wait_set:
                t.cancel()
            await asyncio.gather(*wait_set, return_exceptions=True)
            ACTIVE_TASKS.difference_update(wait_set)
            return False

        if sonos_resume_task and sonos_resume_task in done:
            logger.info("spotify: attempt %d ended because sonos resumed", attempt)
            for t in wait_set:
                t.cancel()
            await asyncio.gather(*wait_set, return_exceptions=True)
            ACTIVE_TASKS.difference_update(wait_set)
            return True

        if spotify_task in done:
            spotify_result = await asyncio.gather(spotify_task, return_exceptions=True)
            logger.warning(
                "spotify: attempt %d finished; connection_stop=%s ws_state=%s result=%s",
                attempt,
                connection_stop.is_set(),
                channel.application_state,
                spotify_result,
            )
            ACTIVE_TASKS.discard(spotify_task)
            if sonos_resume_task:
                sonos_resume_task.cancel()
                await asyncio.gather(sonos_resume_task, return_exceptions=True)
                ACTIVE_TASKS.discard(sonos_resume_task)

            if connection_stop.is_set() or channel.application_state != WebSocketState.CONNECTED:
                logger.info(
                    "spotify: stopping retries because connection_stop=%s ws_state=%s",
                    connection_stop.is_set(),
                    channel.application_state,
                )
                return False

            logger.info("spotify: retrying after backoff=%.1fs", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 10.0)
            continue

    return False


async def _user_driver(ctx: UserContext) -> None:
    """Owns Sonos/Spotify tasks for a single user and fan-outs to their sessions."""

    defer_sonos: bool = False
    while not ctx.stop_event.is_set():
        config_wait = asyncio.create_task(ctx.config_event.wait())
        stop_wait = asyncio.create_task(ctx.stop_event.wait())
        done, pending = await asyncio.wait(
            {config_wait, stop_wait},
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        if config_wait in done:
            ctx.config_event.clear()
        if ctx.stop_event.is_set():
            break
        if not ctx.channel.has_sessions():
            ctx.stop_event.set()
            break

        enabled = ctx.config.get("enabled", {})
        poll = ctx.config.get("poll", {})
        spotify_enabled = enabled.get("spotify", False)
        sonos_enabled = enabled.get("sonos", False)
        client_spotify_poll = poll.get("spotify")
        client_sonos_poll = poll.get("sonos")

        if not spotify_enabled:
            defer_sonos = False

        # Refresh per-config stop event so running streams can be cancelled when config changes.
        current_stop = ctx.service_stop_event
        if current_stop.is_set():
            current_stop = asyncio.Event()
            ctx.service_stop_event = current_stop

        if not (spotify_enabled or sonos_enabled):
            current_stop.set()
            continue

        while (
            not ctx.stop_event.is_set()
            and not current_stop.is_set()
            and ctx.channel.application_state == WebSocketState.CONNECTED
            and ctx.enabled_any()
        ):
            if STOP_EVENT and STOP_EVENT.is_set():
                ctx.stop_event.set()
                current_stop.set()
                break

            allow_sonos = sonos_enabled and not defer_sonos
            sonos_task: Optional[asyncio.Task] = None

            if allow_sonos:
                logger.info("starting sonos stream (user=%s)", ctx.user_id)
                sonos_task = asyncio.create_task(
                    SONOS_MANAGER.stream(
                        ctx.channel,
                        current_stop,
                        stop_on_idle=spotify_enabled,
                        poll_interval_override=client_sonos_poll,
                        global_stop=STOP_EVENT,
                        no_device_timeout=SONOS_MANAGER.no_device_retry_interval if spotify_enabled else None,
                    )
                )
                ACTIVE_TASKS.add(sonos_task)
                try:
                    await asyncio.wait({sonos_task}, return_when=asyncio.FIRST_COMPLETED)
                except asyncio.CancelledError:
                    ctx.stop_event.set()
                    current_stop.set()
                finally:
                    ACTIVE_TASKS.discard(sonos_task)

                if (
                    ctx.channel.application_state != WebSocketState.CONNECTED
                    or ctx.stop_event.is_set()
                    or current_stop.is_set()
                ):
                    break
                defer_sonos = True
            else:
                if sonos_enabled and defer_sonos:
                    logger.info(
                        "skipping sonos this loop to allow spotify (deferred) user=%s", ctx.user_id
                    )

            if spotify_enabled and not ctx.stop_event.is_set() and not current_stop.is_set():
                if ctx.channel.application_state != WebSocketState.CONNECTED:
                    break
                logger.info("starting spotify stream (fallback loop) user=%s", ctx.user_id)
                assert HTTP_CLIENT is not None
                resume_found = await _spotify_fallback_loop(
                    channel=ctx.channel,
                    token=ctx.token,
                    connection_stop=current_stop,
                    http_client=HTTP_CLIENT,
                    poll_interval_override=client_spotify_poll,
                    sonos_enabled=sonos_enabled,
                    global_stop=STOP_EVENT,
                    safe_close=_safe_close_ws,
                )
                if (
                    resume_found
                    and not ctx.stop_event.is_set()
                    and not current_stop.is_set()
                    and ctx.channel.application_state == WebSocketState.CONNECTED
                ):
                    logger.info(
                        "sonos: playback detected; switching from spotify to sonos (user=%s)", ctx.user_id
                    )
                    defer_sonos = False
                    continue
                else:
                    if (
                        not ctx.stop_event.is_set()
                        and not current_stop.is_set()
                        and ctx.channel.application_state == WebSocketState.CONNECTED
                    ):
                        logger.info(
                            "spotify: fallback ended; retrying loop (user=%s)", ctx.user_id
                        )
                        defer_sonos = False
                        await asyncio.sleep(1)
                        continue
                    break
            else:
                break

    await ctx.channel.close(code=1012, reason="User stop")
    current = asyncio.current_task()
    if current:
        ACTIVE_TASKS.discard(current)
    logger.info("user driver stopped user=%s", ctx.user_id)


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

    user_id = str((user_info.get("payload", {}) or {}).get("sub") or user_info.get("sub") or "")
    if not user_id:
        await _safe_close_ws(ws, code=4401, reason="Missing user id")
        return

    ctx = USER_CONTEXTS.get(user_id)
    if ctx is None:
        ctx = UserContext(user_id=user_id, token=token)
        USER_CONTEXTS[user_id] = ctx
    else:
        ctx.token = token

    session_id = str(id(ws))
    logger.info("ws connect user=%s awaiting client config", user_id)

    await ws.accept(subprotocol=None)
    await ws.send_json({"type": "ready", "user": user_info, "settings": {}})

    await ctx.channel.add(session_id, ws)

    if ctx.driver_task is None or ctx.driver_task.done():
        ctx.stop_event.clear()
        ctx.driver_task = asyncio.create_task(_user_driver(ctx))
        ACTIVE_TASKS.add(ctx.driver_task)

    async def _apply_config(msg: Dict[str, Any]) -> None:
        enabled_cfg = msg.get("enabled") or {}
        poll_cfg = msg.get("poll") or {}
        enabled = {
            "spotify": enabled_cfg.get("spotify", False) is True,
            "sonos": enabled_cfg.get("sonos", False) is True,
        }
        poll = {
            "spotify": poll_cfg.get("spotify") if isinstance(poll_cfg.get("spotify"), (int, float)) else None,
            "sonos": poll_cfg.get("sonos") if isinstance(poll_cfg.get("sonos"), (int, float)) else None,
        }
        async with ctx.lock:
            ctx.config = {"enabled": enabled, "poll": poll}
            # Signal current streams to stop when config flips services off, then prepare a fresh stop event.
            ctx.service_stop_event.set()
            ctx.service_stop_event = asyncio.Event()
        ctx.config_event.set()
        logger.info(
            "config updated user=%s enabled_spotify=%s enabled_sonos=%s poll_spotify=%s poll_sonos=%s sessions=%d (multi-session allowed)",
            user_id,
            enabled["spotify"],
            enabled["sonos"],
            poll["spotify"],
            poll["sonos"],
            len(ctx.channel.sessions),
        )

    try:
        while True:
            msg = await ws.receive_json()
            if isinstance(msg, dict) and msg.get("type") == "config":
                await _apply_config(msg)
    except asyncio.CancelledError:
        pass
    except Exception:
        logger.info("ws closed user=%s", user_id)
    finally:
        await ctx.channel.remove(session_id)
        if not ctx.channel.has_sessions():
            ctx.stop_event.set()
            await ctx.channel.close(code=1012, reason="No active sessions")
            if ctx.driver_task:
                ctx.driver_task.cancel()
                with contextlib.suppress(Exception):
                    await ctx.driver_task
                ACTIVE_TASKS.discard(ctx.driver_task)
            USER_CONTEXTS.pop(user_id, None)
        await _safe_close_ws(ws, code=1012, reason="Server shutting down")


if __name__ == "__main__":
    import uvicorn

    def resolve_path(path: Optional[str]) -> Optional[str]:
        if not path:
            return None
        if os.path.isabs(path):
            return path
        return os.path.join(PROJECT_ROOT, path)

    ssl_enabled = WS_CFG.get("sslEnabled", False)
    ssl_cert = resolve_path(WS_CFG.get("sslCertFile")) if ssl_enabled else None
    ssl_key = resolve_path(WS_CFG.get("sslKeyFile")) if ssl_enabled else None

    uvicorn.run(
        "app:app",
        host=WS_CFG.get("host", "0.0.0.0"),
        port=WS_CFG.get("port", 5002),
        ssl_certfile=ssl_cert,
        ssl_keyfile=ssl_key,
        timeout_graceful_shutdown=SERVER_CFG.get("timeoutGracefulShutdownSec", 1),
        reload=False,
    )
