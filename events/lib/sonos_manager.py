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
        self.discovery_retry_interval = config.get("deviceDiscRetryIntervalSec", 5)
        self.retry_window = config.get("discoveryRetryWindowSec", 3600)
        self.cooldown = config.get("discoveryCooldownSec", 1800)
        self.coordinator_retry = config.get("coordinatorRetrySec", 3)
        self.poll_interval = config.get("pollIntervalSec", 5)
        self.stuck_timeout = config.get("idleStuckTimeoutSec", 10)
        self.discovery_cache_ttl = config.get("discoveryCacheTtlSec", 60)
        self._cached_coordinator: Optional[SoCo] = None
        self._cached_at: float = 0.0
        self._cached_ip: Optional[str] = None
        self._cached_uid: Optional[str] = None
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

    def _cache_coordinator(self, coord: SoCo) -> Optional[SoCo]:
        """Cache a verified group coordinator and return it."""
        try:
            ip_addr = coord.ip_address
        except Exception:
            ip_addr = None
        try:
            uid = coord.uid
        except Exception:
            uid = None
        # Only cache if the device currently identifies as coordinator
        try:
            is_coord = bool(getattr(coord, "is_coordinator", False))
        except Exception:
            is_coord = False
        if ip_addr is None or uid is None or not is_coord:
            return None
        self._cached_coordinator = coord
        self._cached_ip = ip_addr
        self._cached_uid = uid
        self._cached_at = time.monotonic()
        return coord

    async def discover_coordinator(self) -> Optional[SoCo]:
        loop = asyncio.get_running_loop()
        now = time.monotonic()

        # First try a cached coordinator object if it's still fresh
        if self._cached_coordinator and (now - self._cached_at) < self.discovery_cache_ttl:
            try:
                grp = self._cached_coordinator.group
                coord = grp.coordinator if grp else None
                coord_uid = getattr(coord, "uid", None) if coord else None
                coord_ip = getattr(coord, "ip_address", None) if coord else None
                is_coord = bool(getattr(coord, "is_coordinator", False)) if coord else False
                if coord and is_coord and self._cached_ip and self._cached_uid and coord_ip == self._cached_ip and coord_uid == self._cached_uid:
                    try:
                        self.logger.info(f"sonos: using cached coordinator {coord.player_name}")
                    except Exception:
                        pass
                    return self._cache_coordinator(coord)
            except Exception:
                self._cached_coordinator = None

        # If we have a cached IP, try to reconnect even if the object cache expired
        if self._cached_ip:
            try:
                candidate = SoCo(self._cached_ip)
                grp = candidate.group
                coord = grp.coordinator if grp else None
                coord_uid = getattr(coord, "uid", None) if coord else None
                coord_ip = getattr(coord, "ip_address", None) if coord else None
                is_coord = bool(getattr(coord, "is_coordinator", False)) if coord else False
                if coord and is_coord and coord_uid and coord_ip and self._cached_uid and coord_ip == self._cached_ip and coord_uid == self._cached_uid:
                    cached = self._cache_coordinator(coord)
                    if cached:
                        self.logger.info(f"sonos: reused cached coordinator {coord.player_name} via IP {self._cached_ip}")
                        return cached
            except Exception:
                self.logger.info("sonos: cached coordinator reuse failed; falling back to discovery")
                self._cached_coordinator = None
                self._cached_ip = None
                self._cached_uid = None

        self.logger.info("sonos: discovering devices")
        devices = await loop.run_in_executor(None, discover)
        if not devices:
            self.logger.info("sonos: no devices discovered")
            return None
        for dev in devices:
            try:
                grp = dev.group
                coord = grp.coordinator if grp else None
                if coord:
                    cached = self._cache_coordinator(coord)
                    if cached:
                        self.logger.info(f"sonos: found coordinator {coord.player_name}")
                        return cached
            except Exception:
                continue
        chosen = next(iter(devices)) if devices else None
        if chosen:
            try:
                # Ensure we store the actual group coordinator if available
                grp = chosen.group
                coord = grp.coordinator if grp else None
                coord = coord or chosen
                cached = self._cache_coordinator(coord)
                return cached or coord
            except Exception:
                return chosen
        return None

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
        # Treat buffering/transitioning as active to avoid premature fallback
        is_playing = state_str in {"PLAYING", "TRANSITIONING", "BUFFERING"}

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

    @staticmethod
    def _signature(payload: Dict[str, Any]) -> tuple:
        item = payload.get("item", {}) or {}
        artists = item.get("artists") or []
        return (
            payload.get("state"),
            payload.get("is_playing"),
            payload.get("device", {}).get("name"),
            tuple(payload.get("group_devices") or []),
            item.get("name"),
            item.get("album"),
            tuple(artists),
        )

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
                        await asyncio.sleep(self.discovery_retry_interval)
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

    async def stream(
        self,
        ws,
        stop_event: asyncio.Event,
        *,
        stop_on_idle: bool = False,
        poll_interval_override: Optional[int] = None,
    ) -> None:
        coordinator: Optional[SoCo] = None
        last_payload: Optional[Dict[str, Any]] = None
        loop = asyncio.get_running_loop()
        effective_poll = poll_interval_override or self.poll_interval
        last_signature: Optional[tuple] = None
        last_position_ms: Optional[int] = None
        last_progress_at: float = time.monotonic()
        last_playing_group: list[str] = []
        first_emit = True
        idle_strikes = 0
        stream_started_at = time.monotonic()
        idle_grace_sec = 12
        ever_active = False

        self.logger.info("sonos: stream started")

        while not stop_event.is_set():
            try:
                if coordinator is None:
                    coordinator = await self.discover_coordinator()
                    if coordinator is None:
                        await asyncio.sleep(self.discovery_retry_interval)
                        continue
                    # Emit immediately once a coordinator is found
                    last_signature = None
                    first_emit = True
                    idle_strikes = 0
                    stream_started_at = time.monotonic()

                payload = await loop.run_in_executor(None, self._build_payload, coordinator)

                # If paused/stopped, retain the last active group membership so the client knows prior members
                group_devices = payload.get("group_devices") or []
                if payload.get("is_playing"):
                    if group_devices:
                        last_playing_group = list(group_devices)
                else:
                    if not group_devices and last_playing_group:
                        payload["group_devices"] = list(last_playing_group)

                send_always = poll_interval_override is not None
                signature = self._signature(payload)
                signature_changed = signature != last_signature

                if send_always or first_emit or signature_changed:
                    if ws.application_state != WebSocketState.CONNECTED:
                        self.logger.info("sonos: websocket not connected, stopping stream")
                        stop_event.set()
                        break
                    try:
                        self.logger.info("sonos: new payload emitted")
                        await ws.send_json({"type": "now_playing", "provider": "sonos", "data": payload})
                        last_payload = payload
                        last_signature = signature
                        first_emit = False
                    except Exception as exc:
                        self.logger.warning(f"sonos: failed to send payload; stopping stream: {exc}")
                        break

                # If requested, stop streaming once playback is no longer active to allow fallback
                if stop_on_idle:
                    is_playing = payload.get("is_playing")
                    position_ms = payload.get("position_ms")
                    has_track = bool((payload.get("item") or {}).get("name"))
                    state_str = (payload.get("state") or "").upper()
                    active_state = state_str in {"PLAYING", "TRANSITIONING", "BUFFERING"}
                    if active_state:
                        ever_active = True
                    now = time.monotonic()

                    # During initial grace, don't drop Sonos to allow state to settle
                    if (now - stream_started_at) < idle_grace_sec:
                        await asyncio.sleep(effective_poll)
                        continue

                    if position_ms is not None:
                        if last_position_ms is None or position_ms != last_position_ms:
                            last_progress_at = now
                        last_position_ms = position_ms

                    idle_due_to_state = (not active_state) and not has_track
                    idle_due_to_stuck = False
                    if is_playing:
                        # Treat a stuck or unknown position while in PLAYING as idle to allow fallback
                        idle_due_to_stuck = (now - last_progress_at) >= self.stuck_timeout

                    if idle_due_to_state or idle_due_to_stuck:
                        self.logger.info(
                            "sonos: idle candidate state=%s active=%s ever_active=%s track=%s is_playing=%s pos=%s last_pos=%s last_prog_ago=%.2fs strikes=%d",
                            state_str,
                            active_state,
                            ever_active,
                            has_track,
                            is_playing,
                            position_ms,
                            last_position_ms,
                            now - last_progress_at,
                            idle_strikes,
                        )
                        idle_strikes += 1
                    else:
                        idle_strikes = 0

                    if idle_strikes >= 2 and ever_active:
                        self.logger.info("sonos: idle detected, stopping stream for fallback")
                        break
                await asyncio.sleep(effective_poll)
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
