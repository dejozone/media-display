import asyncio
import logging
import time
from typing import Any, Callable, Dict, Optional, Tuple

try:
    from soco import SoCo
    from soco.discovery import discover
    from starlette.websockets import WebSocketState, WebSocketDisconnect
except ImportError as exc:  # pragma: no cover
    raise ImportError("soco is required for Sonos support; please install soco") from exc

from lib.payload_normalizer import normalize_payload
from lib.service_health import HEALTH_TRACKER, ErrorCode


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
        self.resume_discovery_interval = config.get("resumeDiscoveryIntervalSec", 10)
        self.no_device_retry_interval = config.get("noDeviceRetryIntervalSec", 15)
        self.logger = logging.getLogger("events.sonos")
        self._active_states = {"PLAYING", "TRANSITIONING", "BUFFERING"}
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

    async def discover_coordinator(
        self,
        on_status_change: Optional[Callable[[Dict[str, Any]], Any]] = None,
    ) -> Tuple[Optional[SoCo], int]:
        """Discover Sonos coordinator.
        
        Args:
            on_status_change: Optional callback for health status changes.
            
        Returns:
            Tuple of (coordinator, device_count). Coordinator may be None if no devices found.
        """
        loop = asyncio.get_running_loop()

        self.logger.info("sonos: discovering devices")
        try:
            devices = await loop.run_in_executor(None, discover)
        except Exception as exc:
            self.logger.warning(f"sonos: discovery failed with error: {exc}")
            status = await HEALTH_TRACKER.report_error(
                "sonos", ErrorCode.NETWORK_ERROR, f"Discovery failed: {exc}"
            )
            if on_status_change and status:
                await on_status_change(status)
            return None, 0
            
        if not devices:
            self.logger.info("sonos: no devices discovered")
            status = await HEALTH_TRACKER.report_error(
                "sonos", ErrorCode.NO_DEVICES, "No Sonos devices found on network"
            )
            if on_status_change and status:
                await on_status_change(status)
            return None, 0

        device_count = len(devices)

        def _sort_key(dev: SoCo) -> str:
            try:
                name = getattr(dev, "player_name", None)
                ip = getattr(dev, "ip_address", None)
                return str(name or ip or "")
            except Exception:
                return ""

        sorted_devices = sorted(devices, key=_sort_key)

        active_coord = None
        fallback_coord = None

        for dev in sorted_devices:
            try:
                grp = dev.group
                coord = grp.coordinator if grp else dev
                if not coord:
                    continue
                # remember first viable coordinator as fallback
                fallback_coord = fallback_coord or coord

                try:
                    tinfo = coord.get_current_transport_info()
                    state = (tinfo.get("current_transport_state") or "").upper()
                except Exception:
                    state = ""

                if state in self._active_states:
                    active_coord = coord
                    break
            except Exception as exc:
                self.logger.debug(f"sonos: error checking device {dev}: {exc}")
                continue

        chosen = active_coord or fallback_coord
        if chosen:
            try:
                self.logger.info(f"sonos: found coordinator {chosen.player_name}")
            except Exception:
                pass
            # Report healthy status
            status = await HEALTH_TRACKER.report_healthy("sonos", device_count)
            if on_status_change and status:
                await on_status_change(status)
            return chosen, device_count

        # Devices found but no coordinator - coordinator error
        self.logger.warning("sonos: devices found but no valid coordinator")
        status = await HEALTH_TRACKER.report_error(
            "sonos", ErrorCode.COORDINATOR_ERROR, f"Found {device_count} devices but no valid coordinator"
        )
        if on_status_change and status:
            await on_status_change(status)
        return None, device_count

    def _build_payload(self, coordinator: SoCo) -> Dict[str, Any]:
        track_info = coordinator.get_current_track_info()
        transport_info = coordinator.get_current_transport_info()

        # Sonos often returns a relative album art path; normalize to absolute
        album_art = track_info.get("album_art")
        if album_art and isinstance(album_art, str) and album_art.startswith("/"):
            try:
                ip = coordinator.ip_address
                album_art = f"http://{ip}:1400{album_art}"
            except Exception:
                pass

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
            "album_art_url": album_art,
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

    async def wait_for_playback(
        self,
        stop_event: asyncio.Event,
        poll_interval: Optional[int] = None,
        global_stop: Optional[asyncio.Event] = None,
    ) -> bool:
        """Block until any Sonos coordinator is playing or stop_event is set.

        Returns True if playback detected, False if stopped/timeout via stop_event.
        """
        coordinator: Optional[SoCo] = None
        loop = asyncio.get_running_loop()
        interval = poll_interval or self.poll_interval
        last_discovery_at = 0.0

        while not stop_event.is_set() and not (global_stop and global_stop.is_set()):
            try:
                now = time.monotonic()
                if coordinator is None or (now - last_discovery_at) >= self.resume_discovery_interval:
                    coordinator, _ = await self.discover_coordinator()
                    last_discovery_at = time.monotonic()
                    if coordinator is None:
                        await asyncio.sleep(self.discovery_retry_interval)
                        continue

                payload = await loop.run_in_executor(None, self._build_payload, coordinator)
                if payload.get("is_playing"):
                    try:
                        self.logger.info("sonos: playback detected during watch (%s)", payload.get("device", {}).get("name"))
                    except Exception:
                        pass
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
        global_stop: Optional[asyncio.Event] = None,
        no_device_timeout: Optional[float] = None,
        on_status_change: Optional[Callable[[Dict[str, Any]], Any]] = None,
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
        idle_time_gate_sec = 10
        no_device_deadline = None if no_device_timeout is None else time.monotonic() + no_device_timeout
        last_device_count = 0

        self.logger.info("sonos: stream started")

        while not stop_event.is_set() and not (global_stop and global_stop.is_set()):
            try:
                self.logger.debug(
                    "sonos: loop tick stop_event=%s global_stop=%s ws_state=%s",
                    stop_event.is_set(),
                    bool(global_stop and global_stop.is_set()),
                    ws.application_state,
                )
                if ws.application_state != WebSocketState.CONNECTED:
                    self.logger.info("sonos: websocket not connected (pre-loop), stopping stream")
                    stop_event.set()
                    break

                if coordinator is None:
                    coordinator, device_count = await self.discover_coordinator(on_status_change)
                    last_device_count = device_count
                    if coordinator is None:
                        if no_device_deadline is not None and time.monotonic() >= no_device_deadline:
                            self.logger.info(
                                "sonos: no devices found within %.1fs; yielding to fallback",
                                no_device_timeout,
                            )
                            break
                        await asyncio.sleep(self.discovery_retry_interval)
                        continue
                    # Emit immediately once a coordinator is found
                    last_signature = None
                    first_emit = True
                    idle_strikes = 0
                    stream_started_at = time.monotonic()
                    if no_device_deadline is not None:
                        # Reset deadline after first discovery so later losses don't auto-break
                        no_device_deadline = None

                payload = await loop.run_in_executor(None, self._build_payload, coordinator)

                if stop_event.is_set() or ws.application_state != WebSocketState.CONNECTED:
                    self.logger.info(
                        "sonos: websocket not connected before send, stopping stream (stop_event=%s ws_state=%s)",
                        stop_event.is_set(),
                        ws.application_state,
                    )
                    stop_event.set()
                    break

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
                    if stop_event.is_set() or ws.application_state != WebSocketState.CONNECTED:
                        self.logger.info("sonos: websocket not connected, stopping stream")
                        stop_event.set()
                        break
                    try:
                        normalized = normalize_payload(payload, "sonos")
                        await ws.send_json({"type": "now_playing", "provider": "sonos", "data": normalized})
                        self.logger.info("sonos: new payload emitted")
                        last_payload = payload
                        last_signature = signature
                        first_emit = False
                    except WebSocketDisconnect:
                        self.logger.info("sonos: websocket disconnect during send; stopping stream")
                        stop_event.set()
                        break
                    except Exception:
                        # If the socket dropped between check and send, exit quietly to avoid noisy warnings
                        self.logger.info("sonos: websocket closed during send; stopping stream")
                        stop_event.set()
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

                    if idle_strikes >= 2 and (ever_active or (now - stream_started_at) >= idle_time_gate_sec):
                        self.logger.info("sonos: idle detected, stopping stream for fallback")
                        break
                await asyncio.sleep(effective_poll)
            except asyncio.CancelledError:
                self.logger.info(
                    "sonos: stream cancelled (stop_event=%s global_stop=%s ws_state=%s)",
                    stop_event.is_set(),
                    bool(global_stop and global_stop.is_set()),
                    ws.application_state,
                )
                break
            except WebSocketDisconnect:
                self.logger.info("sonos: websocket disconnect; stopping stream")
                stop_event.set()
                break
            except Exception as exc:
                # Reset coordinator on any failure and retry soon
                self.logger.warning(f"sonos: stream error, resetting coordinator: {exc}")
                coordinator = None
                # Report error status (may be None if debounced)
                if on_status_change:
                    status = await HEALTH_TRACKER.report_error(
                        "sonos", ErrorCode.COORDINATOR_ERROR, f"Stream error: {exc}"
                    )
                    if status:
                        try:
                            await on_status_change(status)
                        except Exception:
                            pass
                await asyncio.sleep(self.coordinator_retry)
                continue

        # On exit, nothing special; caller handles ws closure
        self.logger.info(
            "sonos: stream stopped (stop_event=%s global_stop=%s ws_state=%s)",
            stop_event.is_set(),
            bool(global_stop and global_stop.is_set()),
            ws.application_state,
        )
        return
