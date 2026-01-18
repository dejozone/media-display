import asyncio
import logging
import time
from typing import Any, Awaitable, Callable, Dict, Optional

import httpx
from starlette.websockets import WebSocket, WebSocketDisconnect, WebSocketState


class SpotifyManager:
    def __init__(self, config: Dict[str, Any], api_base_url: str):
        self.config = config or {}
        self.api_base_url = api_base_url
        self.logger = logging.getLogger("events.spotify")

    async def stream_now_playing(
        self,
        *,
        ws: WebSocket,
        token: str,
        stop_event: asyncio.Event,
        http_client: httpx.AsyncClient,
        close_on_stop: bool = True,
        poll_interval_override: Optional[int] = None,
        safe_close: Optional[Callable[[WebSocket, int, str], Awaitable[None]]] = None,
    ) -> None:
        assert stop_event is not None
        assert http_client is not None

        poll_interval = poll_interval_override or self.config.get("pollIntervalSec", 5)
        retry_interval = self.config.get("retryIntervalSec", 2)
        retry_window = self.config.get("retryWindowSec", 20)
        cooldown = self.config.get("cooldownSec", 1800)

        async def _safe_close(target_ws: WebSocket, code: int, reason: str = "") -> None:
            try:
                if target_ws.application_state == WebSocketState.CONNECTED:
                    await target_ws.close(code=code, reason=reason)
            except Exception:
                pass

        closer = safe_close or _safe_close

        etag: Optional[str] = None
        last_payload: Optional[Dict[str, Any]] = None
        failure_start: Optional[float] = None

        while not stop_event.is_set() and ws.application_state == WebSocketState.CONNECTED:
            try:
                headers = {"Authorization": f"Bearer {token}"}
                if etag:
                    headers["If-None-Match"] = etag

                self.logger.debug("spotify: poll now-playing")
                resp = await http_client.get(
                    f"{self.api_base_url}/api/spotify/now-playing",
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
                    await closer(ws, 4401, "Unauthorized")
                    break
                elif resp.status_code >= 500:
                    resp.raise_for_status()
                else:
                    payload = resp.json()
                    etag = resp.headers.get("ETag", etag)
                    if payload != last_payload:
                        self.logger.info("spotify: new now-playing payload")
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
                self.logger.info("spotify: stream cancelled")
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
                self.logger.info("spotify: websocket disconnect")
                stop_event.set()
                break
            except Exception:
                try:
                    await ws.send_json({"type": "error", "error": "internal_error"})
                finally:
                    await closer(ws, 1011, "")
                break

        if close_on_stop:
            await closer(ws, 1000, "")
        self.logger.info("spotify: stream closed")
