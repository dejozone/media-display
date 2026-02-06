import asyncio
import logging
import time
from typing import Any, Awaitable, Callable, Dict, Optional, Protocol

import httpx
from starlette.websockets import WebSocketDisconnect, WebSocketState

from lib.payload_normalizer import normalize_payload
from lib.service_health import HEALTH_TRACKER, ErrorCode


class SupportsWebSocket(Protocol):
    """Minimal protocol for objects that behave like a WebSocket."""

    @property
    def application_state(self) -> WebSocketState:
        ...

    async def send_json(self, data: Any, mode: str = "text") -> None:
        ...

    async def close(self, code: int = 1000, reason: str = "") -> None:  # pragma: no cover - signature only
        ...


class SpotifyManager:
    def __init__(self, config: Dict[str, Any], api_base_url: str):
        self.config = config or {}
        self.api_base_url = api_base_url
        self.logger = logging.getLogger("events.spotify")

    async def stream_now_playing(
        self,
        *,
        ws: SupportsWebSocket,
        token: str,
        user_id: str,
        stop_event: asyncio.Event,
        http_client: httpx.AsyncClient,
        close_on_stop: bool = True,
        poll_interval_override: Optional[int] = None,
        safe_close: Optional[Callable[[SupportsWebSocket, int, str], Awaitable[None]]] = None,
        on_status_change: Optional[Callable[[Dict[str, Any]], Awaitable[None]]] = None,
    ) -> None:
        """Stream Spotify now-playing data via polling.
        
        Args:
            ws: WebSocket to send data to.
            token: User's auth token.
            user_id: User ID.
            stop_event: Event to signal stop.
            http_client: HTTP client for API calls.
            close_on_stop: Whether to close WebSocket on stop.
            poll_interval_override: Override poll interval from config.
            safe_close: Custom close function.
            on_status_change: Callback for health status changes (may be None if debounced).
        """
        assert stop_event is not None
        assert http_client is not None
        assert user_id is not None

        poll_interval = poll_interval_override or self.config.get("pollIntervalSec", 5)
        retry_interval = max(1, self.config.get("retryIntervalSec", 2))
        retry_window = max(5, self.config.get("retryWindowSec", 20))
        # Avoid very long cooldowns so we can recover quickly once the API is back
        cooldown = min(max(5, self.config.get("cooldownSec", 30)), 120)

        async def _safe_close(target_ws: SupportsWebSocket, code: int, reason: str = "") -> None:
            try:
                if target_ws.application_state == WebSocketState.CONNECTED:
                    await target_ws.close(code=code, reason=reason)
            except Exception:
                pass

        closer = safe_close or _safe_close
        
        async def _report_status(status: Optional[Dict[str, Any]], is_healthy: bool = False) -> None:
            """Report status if callback provided and status is not None (debounced).

            HealthTracker now handles suppression/intervals; always forward what it emits.
            """
            if on_status_change and status:
                try:
                    await on_status_change(status)
                    if is_healthy:
                        self.logger.info("spotify: emitted healthy status")
                except Exception:
                    pass

        etag: Optional[str] = None
        last_payload: Optional[Dict[str, Any]] = None
        failure_start: Optional[float] = None
        was_healthy: bool = True  # Track if we were healthy before
        # HealthTracker handles suppression/interval cadence; no local counter needed

        while not stop_event.is_set() and ws.application_state == WebSocketState.CONNECTED:
            try:
                headers = {"Authorization": f"Bearer {token}"}
                if etag:
                    headers["If-None-Match"] = etag

                self.logger.debug("spotify: poll now-playing")
                resp = await http_client.get(
                    f"{self.api_base_url}/api/users/{user_id}/services/spotify/now-playing",
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
                    self.logger.warning("spotify: rate limited, backing off %ss", retry_after)
                    # Report rate limited status
                    status = await HEALTH_TRACKER.report_error(
                        "spotify", ErrorCode.RATE_LIMITED, f"Rate limited, retry after {retry_after}s"
                    )
                    await _report_status(status, is_healthy=False)
                    was_healthy = False
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
                    # Not modified - still healthy
                    if not was_healthy:
                        status = await HEALTH_TRACKER.report_healthy("spotify")
                        await _report_status(status, is_healthy=True)
                        was_healthy = True
                    if failure_start is not None:
                        recovered_for = time.monotonic() - failure_start
                        self.logger.info("spotify: recovered after %.1fs of errors", recovered_for)
                    failure_start = None
                elif resp.status_code == 401:
                    # Auth error - report and close
                    status = await HEALTH_TRACKER.report_error(
                        "spotify", ErrorCode.AUTH_ERROR, "Unauthorized - token may be expired"
                    )
                    await _report_status(status, is_healthy=False)
                    await closer(ws, 4401, "Unauthorized")
                    break
                elif resp.status_code >= 500:
                    # Server error - will be caught by raise_for_status
                    resp.raise_for_status()
                else:
                    # Success - report healthy if we weren't before
                    if not was_healthy:
                        status = await HEALTH_TRACKER.report_healthy("spotify")
                        await _report_status(status, is_healthy=True)
                        was_healthy = True
                    
                    payload = resp.json()
                    etag = resp.headers.get("ETag", etag)
                    if payload != last_payload:
                        self.logger.info("spotify: new now-playing payload")
                        normalized = normalize_payload(payload, "spotify")
                        await ws.send_json({
                            "type": "now_playing",
                            "provider": "spotify",
                            "data": normalized,
                        })
                        last_payload = payload
                    if failure_start is not None:
                        recovered_for = time.monotonic() - failure_start
                        self.logger.info("spotify: recovered after %.1fs of errors", recovered_for)
                    failure_start = None

                await asyncio.wait_for(asyncio.sleep(poll_interval), timeout=poll_interval + 1)
                continue

            except asyncio.CancelledError:
                self.logger.info("spotify: stream cancelled")
                break
            except httpx.HTTPStatusError as exc:
                # Handle 5xx errors specifically
                if stop_event.is_set():
                    break
                status_code = exc.response.status_code if exc.response else 0
                if status_code >= 500:
                    status = await HEALTH_TRACKER.report_error(
                        "spotify", ErrorCode.SERVER_ERROR, f"Server error: {status_code}"
                    )
                    await _report_status(status, is_healthy=False)
                    was_healthy = False
                # Fall through to general error handling
                now = time.monotonic()
                if failure_start is None:
                    self.logger.warning("spotify: poll error starting failure window: %s", exc)
                    failure_start = now
                else:
                    self.logger.warning(
                        "spotify: poll error during failure window (elapsed=%.1fs): %s",
                        now - failure_start,
                        exc,
                    )
                elapsed = now - failure_start
                if elapsed >= retry_window:
                    self.logger.warning("spotify: cooldown %.1fs after failure window", cooldown)
                    try:
                        await asyncio.wait_for(asyncio.sleep(cooldown), timeout=cooldown + 1)
                    except asyncio.CancelledError:
                        break
                    failure_start = None
                else:
                    self.logger.info("spotify: retrying after %.1fs (within failure window)", retry_interval)
                    try:
                        await asyncio.wait_for(asyncio.sleep(retry_interval), timeout=retry_interval + 1)
                    except asyncio.CancelledError:
                        break
                continue
            except (httpx.TimeoutException, httpx.TransportError) as exc:
                if stop_event.is_set():
                    break
                # Report network/timeout error
                error_code = ErrorCode.TIMEOUT if isinstance(exc, httpx.TimeoutException) else ErrorCode.NETWORK_ERROR
                status = await HEALTH_TRACKER.report_error(
                    "spotify", error_code, f"Connection error: {exc}"
                )
                await _report_status(status, is_healthy=False)
                was_healthy = False
                
                now = time.monotonic()
                if failure_start is None:
                    self.logger.warning("spotify: poll error starting failure window: %s", exc)
                    failure_start = now
                else:
                    self.logger.warning(
                        "spotify: poll error during failure window (elapsed=%.1fs): %s",
                        now - failure_start,
                        exc,
                    )
                elapsed = now - failure_start
                if elapsed >= retry_window:
                    self.logger.warning("spotify: cooldown %.1fs after failure window", cooldown)
                    try:
                        await asyncio.wait_for(asyncio.sleep(cooldown), timeout=cooldown + 1)
                    except asyncio.CancelledError:
                        break
                    failure_start = None
                else:
                    self.logger.info("spotify: retrying after %.1fs (within failure window)", retry_interval)
                    try:
                        await asyncio.wait_for(asyncio.sleep(retry_interval), timeout=retry_interval + 1)
                    except asyncio.CancelledError:
                        break
                continue
            except WebSocketDisconnect:
                self.logger.info("spotify: websocket disconnect")
                stop_event.set()
                break
            except Exception as exc:
                # Report unknown error
                status = await HEALTH_TRACKER.report_error(
                    "spotify", ErrorCode.UNKNOWN, f"Unexpected error: {exc}"
                )
                await _report_status(status, is_healthy=False)
                try:
                    await ws.send_json({"type": "error", "error": "internal_error"})
                finally:
                    await closer(ws, 1011, "")
                break

        if close_on_stop:
            await closer(ws, 1000, "")
        self.logger.info("spotify: stream closed")

    async def check_health(
        self,
        *,
        token: str,
        user_id: str,
        http_client: httpx.AsyncClient,
    ) -> Dict[str, Any]:
        """Check Spotify service health by making a quick API call.
        
        Args:
            token: User's auth token.
            user_id: User ID.
            http_client: HTTP client for API calls.
            
        Returns:
            Health status dict (same format as HEALTH_TRACKER messages).
        """
        try:
            headers = {"Authorization": f"Bearer {token}"}
            resp = await http_client.get(
                f"{self.api_base_url}/api/users/{user_id}/services/spotify/now-playing",
                headers=headers,
            )
            
            if resp.status_code == 429:
                # Rate limited
                status = await HEALTH_TRACKER.report_error(
                    "spotify", ErrorCode.RATE_LIMITED, "Rate limited"
                )
                return status or HEALTH_TRACKER.get_status("spotify") or self._build_status("recovering", ErrorCode.RATE_LIMITED)
            elif resp.status_code == 401:
                # Auth error
                status = await HEALTH_TRACKER.report_error(
                    "spotify", ErrorCode.AUTH_ERROR, "Unauthorized"
                )
                return status or HEALTH_TRACKER.get_status("spotify") or self._build_status("unavailable", ErrorCode.AUTH_ERROR)
            elif resp.status_code >= 500:
                # Server error
                status = await HEALTH_TRACKER.report_error(
                    "spotify", ErrorCode.SERVER_ERROR, f"Server error: {resp.status_code}"
                )
                return status or HEALTH_TRACKER.get_status("spotify") or self._build_status("recovering", ErrorCode.SERVER_ERROR)
            else:
                # Success
                status = await HEALTH_TRACKER.report_healthy("spotify")
                return status or HEALTH_TRACKER.get_status("spotify") or self._build_status("healthy", None)
                
        except httpx.TimeoutException as exc:
            status = await HEALTH_TRACKER.report_error(
                "spotify", ErrorCode.TIMEOUT, f"Timeout: {exc}"
            )
            return status or HEALTH_TRACKER.get_status("spotify") or self._build_status("recovering", ErrorCode.TIMEOUT)
        except (httpx.TransportError, Exception) as exc:
            status = await HEALTH_TRACKER.report_error(
                "spotify", ErrorCode.NETWORK_ERROR, f"Network error: {exc}"
            )
            return status or HEALTH_TRACKER.get_status("spotify") or self._build_status("recovering", ErrorCode.NETWORK_ERROR)
    
    def _build_status(self, status: str, error_code: Optional[ErrorCode]) -> Dict[str, Any]:
        """Build a minimal status dict."""
        return {
            "type": "service_status",
            "provider": "spotify",
            "status": status,
            "error_code": error_code.value if error_code else None,
            "message": None,
            "devices_count": 0,
            "retry_in_sec": 0,
            "should_fallback": False,
            "last_healthy_at": None,
        }
