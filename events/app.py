import asyncio
import contextlib
import json
import logging
import os
import random
import time
from typing import Any, Awaitable, Callable, Dict, Optional, Set, Tuple

import httpx
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from starlette.websockets import WebSocketState

from lib.sonos_manager import SonosManager
from lib.spotify_manager import SpotifyManager, SupportsWebSocket
from lib.service_health import HEALTH_TRACKER

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
TOKEN_REFRESH_LEAD = int(SPOTIFY_CFG.get("tokenRefreshLeadTimeSec", 300) or 300)
TOKEN_REFRESH_JITTER = int(SPOTIFY_CFG.get("tokenRefreshJitterSec", 30) or 30)
DEFAULT_FALLBACK_TO_SPOTIFY = bool(SONOS_CFG.get("fallbackToSpotifyOnError", True))

SONOS_MANAGER = SonosManager(SONOS_CFG)
SPOTIFY_MANAGER = SpotifyManager(SPOTIFY_CFG, API_BASE_URL)

# Configure health tracker with service-specific debounce windows
HEALTH_TRACKER.configure({
    "sonos": SONOS_CFG,
    "spotify": SPOTIFY_CFG,
})

logger = logging.getLogger("events")
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s.%(msecs)03d %(levelname)s %(name)s: %(message)s',
    datefmt='%m-%d %H:%M:%S'
)

HTTP_CLIENT: Optional[httpx.AsyncClient] = None
STOP_EVENT: Optional[asyncio.Event] = None
ACTIVE_TASKS: Set[asyncio.Task] = set()
TOKEN_CACHE: Dict[Tuple[str, str], Dict[str, Any]] = {}
TOKEN_TASKS: Dict[Tuple[str, str], asyncio.Task] = {}


def _discard_task(task: Optional[asyncio.Task]) -> None:
    if task is not None:
        ACTIVE_TASKS.discard(task)


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
            "fallback": {"spotify": DEFAULT_FALLBACK_TO_SPOTIFY},
        }
        self.config_event = asyncio.Event()
        self.lock = asyncio.Lock()
        self.token_lock = asyncio.Lock()

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
        for task in list(TOKEN_TASKS.values()):
            task.cancel()
        TOKEN_TASKS.clear()
        TOKEN_CACHE.clear()
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


async def _fetch_spotify_access_token(
    *, user_id: str, user_token: str, http_client: httpx.AsyncClient, force_refresh: bool = False
) -> Optional[Dict[str, Any]]:
    headers = {"Authorization": f"Bearer {user_token}"}
    params = {"force_refresh": "true"} if force_refresh else {}
    try:
        resp = await http_client.get(
            f"{API_BASE_URL}/api/users/{user_id}/services/spotify/access-token",
            headers=headers,
            params=params,
        )
        if resp.status_code != 200:
            logger.warning(
                "spotify token fetch failed status=%s user=%s force_refresh=%s", resp.status_code, user_id, force_refresh
            )
            return None
        data = resp.json() or {}
        access_token = data.get("access_token")
        expires_at = data.get("expires_at")
        if not access_token or expires_at is None:
            logger.warning("spotify token fetch missing fields user=%s", user_id)
            return None
        # expires_at expected as epoch seconds; best-effort parse
        try:
            expires_at_val = float(expires_at)
        except Exception:
            logger.warning("spotify token fetch invalid expires_at user=%s", user_id)
            return None
        return {"access_token": access_token, "expires_at": expires_at_val}
    except httpx.HTTPError as exc:
        logger.warning("spotify token fetch http error user=%s err=%s", user_id, exc)
        return None


async def _ensure_access_token(
    *,
    ctx: UserContext,
    service: str,
    subscribe_channel: Optional[MultiSessionChannel] = None,
    force_refresh: bool = False,
) -> Optional[Dict[str, Any]]:
    assert HTTP_CLIENT is not None
    cache_key = (ctx.user_id, service)
    state = TOKEN_CACHE.get(cache_key)
    now = time.time()

    # Skip cache if force_refresh is requested
    if not force_refresh and state:
        access_token = state.get("access_token")
        expires_at = state.get("expires_at", 0)
        if access_token and expires_at - TOKEN_REFRESH_LEAD > now:
            return state

    async with ctx.token_lock:
        state = TOKEN_CACHE.get(cache_key)
        now = time.time()
        # Skip cache if force_refresh is requested
        if not force_refresh and state:
            access_token = state.get("access_token")
            expires_at = state.get("expires_at", 0)
            if access_token and expires_at - TOKEN_REFRESH_LEAD > now:
                return state

        if service != "spotify":
            return None

        fetched = await _fetch_spotify_access_token(
            user_id=ctx.user_id,
            user_token=ctx.token,
            http_client=HTTP_CLIENT,
            force_refresh=force_refresh,
        )
        if not fetched:
            return None

        TOKEN_CACHE[cache_key] = fetched

        if subscribe_channel:
            _schedule_token_refresh(ctx, service, subscribe_channel)
        return fetched


def _schedule_token_refresh(
    ctx: UserContext,
    service: str,
    channel: MultiSessionChannel,
) -> None:
    cache_key = (ctx.user_id, service)

    existing = TOKEN_TASKS.get(cache_key)
    if existing and not existing.done():
        logger.info("token refresh task already running user=%s", ctx.user_id)
        return

    logger.info("scheduling token refresh task user=%s", ctx.user_id)

    async def _runner() -> None:
        logger.info("token refresh runner started user=%s", ctx.user_id)
        while channel.has_sessions() and not ctx.stop_event.is_set():
            state = TOKEN_CACHE.get(cache_key)
            if not state:
                logger.warning("token refresh runner: no cached state, exiting user=%s", ctx.user_id)
                break
            expires_at = state.get("expires_at", 0)
            now = time.time()
            time_until_expiry = expires_at - now

            # If token is already expired or expiring very soon, fetch immediately
            if time_until_expiry < 60:
                refresh_in = 0.0
            # If token has less time than TOKEN_REFRESH_LEAD, we're already past the
            # intended refresh point - refresh soon with a small delay + jitter
            elif time_until_expiry < TOKEN_REFRESH_LEAD:
                # Already past refresh point, refresh within 10-40 seconds
                refresh_in = 10.0 + random.uniform(0, TOKEN_REFRESH_JITTER)
            else:
                # Normal case: refresh TOKEN_REFRESH_LEAD seconds before expiry
                refresh_in = time_until_expiry - TOKEN_REFRESH_LEAD
                if TOKEN_REFRESH_JITTER:
                    refresh_in = max(0.0, refresh_in - random.uniform(0, TOKEN_REFRESH_JITTER))
                # Ensure minimum sleep time
                refresh_in = max(10.0, refresh_in)

            logger.info(
                "token refresh runner: time_until_expiry=%.1fs, TOKEN_REFRESH_LEAD=%ds, refresh_in=%.1fs user=%s",
                time_until_expiry, TOKEN_REFRESH_LEAD, refresh_in, ctx.user_id
            )

            if refresh_in > 0:
                try:
                    await asyncio.wait_for(asyncio.sleep(refresh_in), timeout=refresh_in + 1)
                except asyncio.CancelledError:
                    logger.info("token refresh runner: cancelled during sleep user=%s", ctx.user_id)
                    break

            # Check conditions again after sleep
            if not channel.has_sessions():
                logger.info("token refresh runner: no sessions after sleep, exiting user=%s", ctx.user_id)
                break
            if ctx.stop_event.is_set():
                logger.info("token refresh runner: stop_event set after sleep, exiting user=%s", ctx.user_id)
                break

            new_state = await _ensure_access_token(
                ctx=ctx,
                service=service,
                subscribe_channel=None,
            )
            if not new_state:
                logger.warning("spotify token refresh failed user=%s", ctx.user_id)
                # Wait before retrying to avoid tight loop
                try:
                    await asyncio.sleep(30)
                except asyncio.CancelledError:
                    break
                continue
            
            # Check if this is actually a new token (different expiry time)
            old_expires = state.get("expires_at", 0)
            new_expires = new_state.get("expires_at", 0)
            if new_expires <= old_expires:
                # Token hasn't been refreshed yet (same or older)
                # Try again with force_refresh to get a new token from Spotify
                logger.info("spotify token same as before user=%s, retrying with force_refresh", ctx.user_id)
                new_state = await _ensure_access_token(
                    ctx=ctx,
                    service=service,
                    subscribe_channel=None,
                    force_refresh=True,
                )
                if not new_state:
                    logger.warning("spotify token force refresh failed user=%s", ctx.user_id)
                    try:
                        await asyncio.sleep(30)
                    except asyncio.CancelledError:
                        break
                    continue
                
                new_expires = new_state.get("expires_at", 0)
                if new_expires <= old_expires:
                    # Still the same token even after force refresh
                    # This means the token hasn't actually expired yet at Spotify's end
                    # Wait until closer to actual expiry
                    time_until_expiry = old_expires - time.time()
                    if time_until_expiry > 120:
                        wait_time = time_until_expiry - 60  # Try again 1 minute before expiry
                        logger.info(
                            "spotify token still not refreshed user=%s, waiting %.1fs until closer to expiry",
                            ctx.user_id, wait_time
                        )
                    else:
                        wait_time = 30.0
                        logger.info("spotify token still not refreshed user=%s, waiting %.1fs", ctx.user_id, wait_time)
                    try:
                        await asyncio.sleep(wait_time)
                    except asyncio.CancelledError:
                        break
                    continue

            try:
                logger.info("emitting spotify_token via scheduled refresh user=%s", ctx.user_id)
                await channel.send_json(
                    {
                        "type": "spotify_token",
                        "access_token": new_state.get("access_token"),
                        "expires_at": new_state.get("expires_at"),
                    }
                )
            except Exception:
                logger.warning("spotify token broadcast failed user=%s", ctx.user_id)
                continue

        logger.info("token refresh runner exited user=%s", ctx.user_id)
        _discard_task(asyncio.current_task())
        TOKEN_TASKS.pop(cache_key, None)

    task = asyncio.create_task(_runner())
    TOKEN_TASKS[cache_key] = task
    ACTIVE_TASKS.add(task)
    logger.info("token refresh task created user=%s task_id=%s", ctx.user_id, id(task))


async def _spotify_fallback_loop(
    *,
    channel: MultiSessionChannel,
    token: str,
    user_id: str,
    connection_stop: asyncio.Event,
    http_client: httpx.AsyncClient,
    poll_interval_override: Optional[int],
    sonos_enabled: bool,
    global_stop: Optional[asyncio.Event],
    safe_close: Callable[[SupportsWebSocket, int, str], Awaitable[None]],
    on_spotify_status: Optional[Callable[[Dict[str, Any]], Awaitable[None]]] = None,
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
                user_id=user_id,
                stop_event=connection_stop,
                http_client=http_client,
                close_on_stop=False,
                poll_interval_override=poll_interval_override,
                safe_close=safe_close,
                on_status_change=on_spotify_status,
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


async def _send_service_status(channel: MultiSessionChannel, status: Optional[Dict[str, Any]]) -> None:
    """Send service status message to all sessions in a channel.
    
    Args:
        channel: The channel to send to.
        status: The status message, or None if debounced (should not send).
    """
    if status is None:
        return  # Debounced, don't send
    try:
        if channel.application_state == WebSocketState.CONNECTED:
            await channel.send_json(status)
            logger.debug("Sent service_status: provider=%s status=%s", status.get("provider"), status.get("status"))
    except Exception as exc:
        logger.warning("Failed to send service_status: %s", exc)


async def _user_driver(ctx: UserContext) -> None:
    """Owns Sonos/Spotify tasks for a single user and fan-outs to their sessions."""

    defer_sonos: bool = False
    try:
        while not ctx.stop_event.is_set():
            config_wait = asyncio.create_task(ctx.config_event.wait())
            stop_wait = asyncio.create_task(ctx.stop_event.wait())
            try:
                done, pending = await asyncio.wait(
                    {config_wait, stop_wait},
                    return_when=asyncio.FIRST_COMPLETED,
                )
            except asyncio.CancelledError:
                config_wait.cancel()
                stop_wait.cancel()
                await asyncio.gather(config_wait, stop_wait, return_exceptions=True)
                raise
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

                fallback_cfg = ctx.config.get("fallback") or {}
                allow_spotify_fallback = bool(fallback_cfg.get("spotify", DEFAULT_FALLBACK_TO_SPOTIFY))

                allow_sonos = sonos_enabled and not defer_sonos
                sonos_task: Optional[asyncio.Task] = None
                spotify_task: Optional[asyncio.Task] = None

                if allow_sonos:
                    logger.info("starting sonos stream (user=%s)", ctx.user_id)

                    async def on_sonos_status(status: Dict[str, Any]) -> None:
                        await _send_service_status(ctx.channel, status)

                    sonos_task = asyncio.create_task(
                        SONOS_MANAGER.stream(
                            ctx.channel,
                            current_stop,
                            # Only stop Sonos on idle when Spotify fallback is allowed; otherwise keep Sonos running.
                            stop_on_idle=spotify_enabled and allow_spotify_fallback,
                            poll_interval_override=client_sonos_poll,
                            global_stop=STOP_EVENT,
                            no_device_timeout=(
                                SONOS_MANAGER.no_device_retry_interval if spotify_enabled and allow_spotify_fallback else None
                            ),
                            on_status_change=on_sonos_status,
                        )
                    )
                    ACTIVE_TASKS.add(sonos_task)
                else:
                    if sonos_enabled and defer_sonos:
                        logger.info(
                            "skipping sonos this loop to allow spotify (deferred) user=%s", ctx.user_id
                        )

                # Start Spotify whenever the client enables it; fallback still controls how Sonos is deferred/resumed.
                if spotify_enabled:
                    if ctx.channel.application_state != WebSocketState.CONNECTED:
                        logger.info("spotify: channel disconnected before start (user=%s)", ctx.user_id)
                    else:
                        logger.info(
                            "starting spotify stream (explicit enable, fallback=%s) user=%s",
                            allow_spotify_fallback,
                            ctx.user_id,
                        )
                        assert HTTP_CLIENT is not None

                        async def on_spotify_status(status: Dict[str, Any]) -> None:
                            await _send_service_status(ctx.channel, status)

                        sonos_for_fallback = sonos_enabled and allow_spotify_fallback
                        spotify_task = asyncio.create_task(
                            _spotify_fallback_loop(
                                channel=ctx.channel,
                                token=ctx.token,
                                user_id=ctx.user_id,
                                connection_stop=current_stop,
                                http_client=HTTP_CLIENT,
                                poll_interval_override=client_spotify_poll,
                                sonos_enabled=sonos_for_fallback,
                                global_stop=STOP_EVENT,
                                safe_close=_safe_close_ws,
                                on_spotify_status=on_spotify_status,
                            )
                        )
                        ACTIVE_TASKS.add(spotify_task)

                # If no tasks started, break out
                if not sonos_task and not spotify_task:
                    if not spotify_enabled:
                        logger.info("no services to run, breaking inner loop (user=%s)", ctx.user_id)
                        break

                tasks_to_wait = {t for t in (sonos_task, spotify_task) if t is not None}
                if tasks_to_wait:
                    try:
                        done, pending = await asyncio.wait(
                            tasks_to_wait, return_when=asyncio.FIRST_COMPLETED
                        )
                    except asyncio.CancelledError:
                        ctx.stop_event.set()
                        current_stop.set()
                        pending = set()
                        done = tasks_to_wait

                    for t in done:
                        ACTIVE_TASKS.discard(t)

                    # If we are stopping or disconnected, cancel any pending tasks
                    if (
                        ctx.stop_event.is_set()
                        or current_stop.is_set()
                        or ctx.channel.application_state != WebSocketState.CONNECTED
                    ):
                        for t in pending:
                            t.cancel()
                        await asyncio.gather(*pending, return_exceptions=True)
                        ACTIVE_TASKS.difference_update(pending)
                        logger.info("breaking inner loop due to stop/disconnect (user=%s)", ctx.user_id)
                        break

                    # Handle Sonos completion
                    if sonos_task in done:
                        if allow_spotify_fallback and spotify_enabled:
                            defer_sonos = True
                            logger.info(
                                "sonos: completed, deferring to spotify (defer=True, user=%s)", ctx.user_id
                            )
                        else:
                            defer_sonos = False
                            logger.info(
                                "sonos: completed; spotify fallback %s, spotify_enabled=%s (user=%s)",
                                "disabled" if not allow_spotify_fallback else "unavailable",
                                spotify_enabled,
                                ctx.user_id,
                            )
                            await asyncio.sleep(1)

                    # Handle Spotify completion
                    if spotify_task in done:
                        defer_sonos = False
                        if sonos_task and sonos_task in pending:
                            # Keep Sonos running; continue loop
                            await asyncio.sleep(0)
                            continue

                    # Cancel any pending tasks before next loop to avoid duplicates
                    for t in pending:
                        t.cancel()
                    await asyncio.gather(*pending, return_exceptions=True)
                    ACTIVE_TASKS.difference_update(pending)
                    continue

    except asyncio.CancelledError:
        logger.info("user driver cancelled user=%s", ctx.user_id)
    finally:
        # Don't close the channel here - let the websocket handler manage it
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

    async def _apply_config(msg: Dict[str, Any]) -> None:
        logger.info("config received user=%s raw_config=%s", user_id, msg)
        need_token = msg.get("need_spotify_token") is True

        # Reset health tracker debounce state so new/reconnecting clients get fresh status
        # This ensures the first health status is always sent after reconnection
        enabled_cfg = msg.get("enabled") or {}
        if enabled_cfg.get("sonos"):
            HEALTH_TRACKER.reset("sonos")
        if enabled_cfg.get("spotify"):
            HEALTH_TRACKER.reset("spotify")

        # If client requests a token, emit it immediately
        # This happens when the client is using direct Spotify polling
        # Note: We don't return early - we still process the full config below
        if need_token:
            cache_key = (ctx.user_id, "spotify")
            existing_task = TOKEN_TASKS.get(cache_key)
            
            # Get token (from cache or fresh fetch)
            token_state = await _ensure_access_token(
                ctx=ctx,
                service="spotify",
                # Only pass subscribe_channel if no refresh task is running
                # This prevents spawning duplicate refresh tasks
                subscribe_channel=ctx.channel if (existing_task is None or existing_task.done()) else None,
            )
            if token_state:
                logger.info(
                    "emitting spotify_token user=%s refresh_task_running=%s",
                    user_id,
                    existing_task is not None and not existing_task.done()
                )
                await ctx.channel.send_json(
                    {
                        "type": "spotify_token",
                        "access_token": token_state.get("access_token"),
                        "expires_at": token_state.get("expires_at"),
                    }
                )

        # Process the config (enabled services and poll intervals)
        enabled_cfg = msg.get("enabled") or {}
        poll_cfg = msg.get("poll") or {}
        fallback_cfg = msg.get("fallback") or {}

        # Start from existing config; only update keys provided by the client.
        enabled: Dict[str, bool] = dict(
            ctx.config.get("enabled") or {"spotify": False, "sonos": False}
        )
        if "spotify" in enabled_cfg:
            enabled["spotify"] = enabled_cfg.get("spotify") is True
        if "sonos" in enabled_cfg:
            enabled["sonos"] = enabled_cfg.get("sonos") is True

        poll: Dict[str, Optional[float]] = dict(
            ctx.config.get("poll") or {"spotify": None, "sonos": None}
        )
        if "spotify" in poll_cfg:
            val = poll_cfg.get("spotify")
            poll["spotify"] = val if isinstance(val, (int, float)) else None
        if "sonos" in poll_cfg:
            val = poll_cfg.get("sonos")
            poll["sonos"] = val if isinstance(val, (int, float)) else None

        # Fallback handling: default to server config unless client explicitly sets.
        fallback = {"spotify": DEFAULT_FALLBACK_TO_SPOTIFY}
        client_fallback_spotify = fallback_cfg.get("spotify")
        if isinstance(client_fallback_spotify, bool):
            fallback["spotify"] = client_fallback_spotify

        # Manage token refresh task based on need_token flag or Spotify enabled state
        # Token refresh task should run when:
        # 1. Client requests token (need_token=true, for direct polling)
        # 2. Server is polling Spotify (enabled.spotify=true)
        cache_key = (ctx.user_id, "spotify")
        need_token_refresh = need_token or enabled["spotify"]
        
        if not need_token_refresh:
            # Cancel token refresh if neither direct polling nor server polling is active
            ttask = TOKEN_TASKS.pop(cache_key, None)
            if ttask and not ttask.done():
                logger.info("cancelling token refresh task (spotify disabled) user=%s", user_id)
                ttask.cancel()
            TOKEN_CACHE.pop(cache_key, None)
        else:
            # Ensure token refresh task is running (only start if not already running)
            existing_task = TOKEN_TASKS.get(cache_key)
            if existing_task is None or existing_task.done():
                # Need to start token refresh task - but only if we haven't already
                # started it above when handling need_token
                if not need_token:
                    # Only fetch token here if we didn't already do it above
                    token_state = await _ensure_access_token(
                        ctx=ctx,
                        service="spotify",
                        subscribe_channel=ctx.channel,  # This will start the refresh task
                    )
                    if token_state:
                        logger.info("token refresh task started (spotify enabled) user=%s", user_id)

        # Enforce minimum poll intervals; if client sends below min, fall back to configured defaults.
        def _apply_min(raw: Optional[float], min_allowed: Optional[float], default_val: Optional[float]) -> Optional[float]:
            if raw is None:
                return None
            if min_allowed is not None and raw < min_allowed:
                return default_val
            return raw

        if "spotify" in poll_cfg:
            poll["spotify"] = _apply_min(
                poll.get("spotify"),
                SPOTIFY_CFG.get("minPollIntervalSec"),
                SPOTIFY_CFG.get("pollIntervalSec"),
            )

        # Sonos: if client sends None, honor None (no polling). Otherwise enforce minimum and default.
        if "sonos" in poll_cfg and poll.get("sonos") is not None:
            poll["sonos"] = _apply_min(
                poll.get("sonos"),
                SONOS_CFG.get("minPollIntervalSec"),
                SONOS_CFG.get("pollIntervalSec"),
            )

        async with ctx.lock:
            ctx.config = {"enabled": enabled, "poll": poll, "fallback": fallback}
            # Signal current streams to stop when config flips services off, then prepare a fresh stop event.
            ctx.service_stop_event.set()
            ctx.service_stop_event = asyncio.Event()
        ctx.config_event.set()
        logger.info(
            "config updated user=%s enable_spotify=%s enable_sonos=%s poll_spotify=%s poll_sonos=%s fallback_spotify=%s sessions=%d raw_config=%s",
            user_id,
            enabled["spotify"],
            enabled["sonos"],
            poll["spotify"],
            poll["sonos"],
            fallback["spotify"],
            len(ctx.channel.sessions),
            msg,
        )

        # Start driver task if not running and at least one service is enabled
        if (enabled["spotify"] or enabled["sonos"]) and (ctx.driver_task is None or ctx.driver_task.done()):
            ctx.stop_event.clear()
            ctx.driver_task = asyncio.create_task(_user_driver(ctx))
            ACTIVE_TASKS.add(ctx.driver_task)

    async def _handle_service_status_request(msg: Dict[str, Any]) -> None:
        """Handle service_status request - check health of specified providers."""
        providers = msg.get("providers", [])
        if not providers:
            logger.warning("service_status request with no providers user=%s", user_id)
            return
        
        logger.info("service_status request for providers=%s user=%s", providers, user_id)
        
        statuses = []
        for provider in providers:
            if provider == "sonos":
                status = await SONOS_MANAGER.check_health()
                statuses.append(status)
            elif provider == "spotify":
                # Need HTTP client and token for Spotify health check
                assert HTTP_CLIENT is not None
                status = await SPOTIFY_MANAGER.check_health(
                    token=ctx.token,
                    user_id=ctx.user_id,
                    http_client=HTTP_CLIENT,
                )
                statuses.append(status)
            else:
                logger.warning("Unknown provider in service_status request: %s", provider)
        
        # Send response with all statuses
        if statuses:
            await ctx.channel.send_json({
                "type": "service_status",
                "statuses": statuses,
            })
            logger.info("Sent service_status response with %d statuses user=%s", len(statuses), user_id)

    try:
        while True:
            msg = await ws.receive_json()
            if isinstance(msg, dict):
                msg_type = msg.get("type")
                if msg_type == "config":
                    await _apply_config(msg)
                elif msg_type == "service_status":
                    await _handle_service_status_request(msg)
    except asyncio.CancelledError:
        pass
    except Exception:
        logger.info("ws closed user=%s", user_id)
    finally:
        await ctx.channel.remove(session_id)
        if not ctx.channel.has_sessions():
            ctx.stop_event.set()
            ctx.service_stop_event.set()
            ctx.config_event.set()

            # Cancel driver task
            driver = ctx.driver_task
            if driver and not driver.done():
                driver.cancel()
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(driver, timeout=2.0)

            # Cancel token refresh/cache for this user
            cache_key = (ctx.user_id, "spotify")
            ttask = TOKEN_TASKS.pop(cache_key, None)
            if ttask and not ttask.done():
                ttask.cancel()
            TOKEN_CACHE.pop(cache_key, None)

            # Reset health tracker so next login emits fresh status
            HEALTH_TRACKER.reset("sonos")
            HEALTH_TRACKER.reset("spotify")

            # Clear config and remove context for this user only
            ctx.config = {
                "enabled": {"spotify": False, "sonos": False},
                "poll": {"spotify": None, "sonos": None},
                "fallback": {"spotify": DEFAULT_FALLBACK_TO_SPOTIFY},
            }
            USER_CONTEXTS.pop(user_id, None)

            await ctx.channel.close(code=1012, reason="No active sessions")

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
    ws_ping_interval = WS_CFG.get("pingIntervalSec", 30)
    ws_ping_timeout = WS_CFG.get("pingTimeoutSec", 10)

    uvicorn.run(
        "app:app",
        host=WS_CFG.get("host", "0.0.0.0"),
        port=WS_CFG.get("port", 5002),
        ssl_certfile=ssl_cert,
        ssl_keyfile=ssl_key,
        timeout_graceful_shutdown=SERVER_CFG.get("timeoutGracefulShutdownSec", 1),
        ws_ping_interval=ws_ping_interval,
        ws_ping_timeout=ws_ping_timeout,
        reload=False,
    )
