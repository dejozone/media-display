import asyncio
import logging
import time
from typing import Any, Dict, Optional

try:
    from soco import SoCo
    from soco.discovery import discover
    from starlette.websockets import WebSocketState
except ImportError as exc:  # pragma: no cover
    raise ImportError("soco is required for Sonos support; please install soco") from exc


class SonosManager:
    """Lightweight Sonos polling manager for local network playback info."""

    def __init__(self, config: Dict[str, Any]):
        self.discovery_interval = config.get("discoveryIntervalSec", 5)
        self.retry_window = config.get("discoveryRetryWindowSec", 3600)
        self.cooldown = config.get("discoveryCooldownSec", 1800)
        self.coordinator_retry = config.get("coordinatorRetrySec", 3)
        self.poll_interval = config.get("pollIntervalSec", 5)
        self.discovery_cache_ttl = config.get("discoveryCacheTtlSec", 60)
        self._cached_coordinator: Optional[SoCo] = None
        self._cached_at: float = 0.0
        self.logger = logging.getLogger("events.sonos")
        # Suppress noisy SoCo UPnP parse errors that are non-fatal
        soco_services = logging.getLogger("soco.services")
        soco_services.setLevel(logging.CRITICAL)
        soco_services.propagate = False

    @staticmethod
    def _parse_ms(time_str: Optional[str]) -> Optional[int]:
        if not time_str:
            return None
        try:
            parts = time_str.split(":")
            total_seconds = 0.0
            for part in parts:
                total_seconds = total_seconds * 60 + float(part)
            return int(total_seconds * 1000)
        except Exception:
            return None

    async def discover_coordinator(self) -> Optional[SoCo]:
        loop = asyncio.get_running_loop()
        now = time.monotonic()

        # Reuse a recently discovered coordinator to avoid repeated network discovery storms
        if self._cached_coordinator and (now - self._cached_at) < self.discovery_cache_ttl:
            try:
                grp = self._cached_coordinator.group
                if grp and grp.coordinator:
                    return grp.coordinator
            except Exception:
                self._cached_coordinator = None

        self.logger.info("sonos: discovering devices")
        devices = await loop.run_in_executor(None, discover)
        if not devices:
            self.logger.info("sonos: no devices discovered")
            return None
        for dev in devices:
            try:
                grp = dev.group
                if grp and grp.coordinator:
                    self._cached_coordinator = grp.coordinator
                    self._cached_at = time.monotonic()
                    self.logger.info(f"sonos: found coordinator {grp.coordinator.player_name}")
                    return grp.coordinator
            except Exception:
                continue
        chosen = next(iter(devices)) if devices else None
        if chosen:
            self._cached_coordinator = chosen
            self._cached_at = time.monotonic()
        return chosen

    def _build_payload(self, coordinator: SoCo) -> Dict[str, Any]:
        track_info = coordinator.get_current_track_info()
        transport_info = coordinator.get_current_transport_info()

        group_devices = []
        try:
            if coordinator.group and coordinator.group.members:
                # Only include members that are actively playing (not paused/idle)
                for member in coordinator.group.members:
                    try:
                        tinfo = member.get_current_transport_info()
                        state = (tinfo.get("current_transport_state") or "").upper()
                        if state == "PLAYING":
                            group_devices.append(member.player_name)
                    except Exception:
                        continue
        except Exception:
            group_devices = []

        state_str = (transport_info.get("current_transport_state") or "").upper()
        is_playing = state_str == "PLAYING"

        item = {
            "name": track_info.get("title"),
            "artists": [track_info.get("artist")] if track_info.get("artist") else [],
            "album": track_info.get("album"),
            "album_art_url": track_info.get("album_art"),
            "duration_ms": self._parse_ms(track_info.get("duration")),
        }

        position_ms = self._parse_ms(track_info.get("position"))

        return {
            "provider": "sonos",
            "device": {"name": coordinator.player_name},
            "group_devices": group_devices,
            "is_playing": is_playing,
            "item": item,
            "position_ms": position_ms,
            "duration_ms": item.get("duration_ms"),
            "state": state_str,
        }

    async def wait_for_playback(self, stop_event: asyncio.Event, poll_interval: Optional[int] = None) -> bool:
        """Block until any Sonos coordinator is playing or stop_event is set.

        Returns True if playback detected, False if stopped/timeout via stop_event.
        """
        coordinator: Optional[SoCo] = None
        loop = asyncio.get_running_loop()
        interval = poll_interval or self.poll_interval

        while not stop_event.is_set():
            try:
                if coordinator is None:
                    coordinator = await self.discover_coordinator()
                    if coordinator is None:
                        await asyncio.sleep(self.discovery_interval)
                        continue

                payload = await loop.run_in_executor(None, self._build_payload, coordinator)
                if payload.get("is_playing"):
                    self.logger.info("sonos: playback detected during watch")
                    return True
                await asyncio.sleep(interval)
            except asyncio.CancelledError:
                break
            except Exception as exc:
                self.logger.warning(f"sonos: watch error, resetting coordinator: {exc}")
                coordinator = None
                await asyncio.sleep(self.coordinator_retry)
                continue

        return False

    async def stream(self, ws, stop_event: asyncio.Event, *, stop_on_idle: bool = False, idle_grace: int = 2) -> None:
        coordinator: Optional[SoCo] = None
        last_payload: Optional[Dict[str, Any]] = None
        failure_start: Optional[float] = None
        cooldown_until: Optional[float] = None
        loop = asyncio.get_running_loop()
        idle_strikes = 0

        self.logger.info("sonos: stream started")

        while not stop_event.is_set():
            now = time.monotonic()
            if cooldown_until and now < cooldown_until:
                await asyncio.sleep(min(5, cooldown_until - now))
                continue

            try:
                if coordinator is None:
                    coordinator = await self.discover_coordinator()
                    if coordinator is None:
                        failure_start = failure_start or time.monotonic()
                        elapsed = time.monotonic() - failure_start
                        if elapsed >= self.retry_window:
                            cooldown_until = time.monotonic() + self.cooldown
                            self.logger.warning(f"sonos: discovery cooling down for {self.cooldown}s")
                            failure_start = None
                        else:
                            await asyncio.sleep(self.discovery_interval)
                        continue
                    failure_start = None

                payload = await loop.run_in_executor(None, self._build_payload, coordinator)
                if payload != last_payload:
                    if ws.application_state != WebSocketState.CONNECTED:
                        self.logger.info("sonos: websocket not connected, stopping stream")
                        break
                    try:
                        self.logger.info("sonos: new payload emitted")
                        await ws.send_json({"type": "now_playing", "provider": "sonos", "data": payload})
                        last_payload = payload
                    except Exception as exc:
                        self.logger.warning(f"sonos: failed to send payload; stopping stream: {exc}")
                        break

                # If requested, stop streaming after repeated idle/paused states to allow fallback
                if stop_on_idle:
                    if payload.get("is_playing") is True:
                        idle_strikes = 0
                    else:
                        idle_strikes += 1
                        if idle_strikes >= idle_grace:
                            self.logger.info("sonos: idle detected, stopping stream for fallback")
                            break
                await asyncio.sleep(self.poll_interval)
            except asyncio.CancelledError:
                self.logger.info("sonos: stream cancelled")
                break
            except Exception as exc:
                # Reset coordinator on any failure and retry soon
                self.logger.warning(f"sonos: stream error, resetting coordinator: {exc}")
                coordinator = None
                await asyncio.sleep(self.coordinator_retry)
                continue

        # On exit, nothing special; caller handles ws closure
        self.logger.info("sonos: stream stopped")
        return
