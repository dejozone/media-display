"""
Payload normalizer for track information from different providers.
Normalizes Spotify and Sonos payloads into a common structure.
"""
from typing import Any, Dict, List, Optional


def normalize_spotify_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Normalize Spotify API response into common structure.
    
    Expected input structure:
    {
        "item": {
            "name": "Track Name",
            "artists": [{"name": "Artist"}],
            "album": {
                "name": "Album",
                "images": [{"url": "..."}]
            },
            "duration_ms": 123456
        },
        "is_playing": true,
        "progress_ms": 12345,
        "device": {"name": "Device Name", "type": "Computer"},
        ...
    }
    """
    item = payload.get("item") or {}
    device = payload.get("device") or {}
    
    # Extract artist names
    artists = item.get("artists") or []
    artist_names = []
    for artist in artists:
        if isinstance(artist, dict) and "name" in artist:
            artist_names.append(artist["name"])
        elif isinstance(artist, str):
            artist_names.append(artist)
    artist_str = ", ".join(artist_names) if artist_names else None
    
    # Extract album info
    album = item.get("album") or {}
    album_name = None
    artwork_url = None
    
    if isinstance(album, dict):
        album_name = album.get("name") or album.get("title")
        images = album.get("images") or []
        if images and isinstance(images, list):
            for img in images:
                if isinstance(img, dict) and img.get("url"):
                    artwork_url = img["url"]
                    break
                elif isinstance(img, str):
                    artwork_url = img
                    break
    elif isinstance(album, str):
        album_name = album
    
    # Fallback to top-level images if album images not found
    if not artwork_url:
        images = item.get("images") or payload.get("images") or []
        if isinstance(images, list):
            for img in images:
                if isinstance(img, dict) and img.get("url"):
                    artwork_url = img["url"]
                    break
                elif isinstance(img, str):
                    artwork_url = img
                    break
    
    # Handle podcast shows
    if not album_name:
        show = item.get("show")
        if isinstance(show, dict):
            album_name = show.get("name")
    
    return {
        "track": {
            "title": item.get("name"),
            "artist": artist_str,
            "album": album_name,
            "artwork_url": artwork_url,
            "duration_ms": item.get("duration_ms"),
        },
        "playback": {
            "is_playing": payload.get("is_playing", False),
            "progress_ms": payload.get("progress_ms"),
            "timestamp": payload.get("timestamp"),
            "status": "playing" if payload.get("is_playing") else "paused",
        },
        "device": {
            "name": device.get("name"),
            "type": device.get("type"),
            "id": device.get("id"),
        },
        "provider": "spotify",
    }


def normalize_sonos_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Normalize Sonos response into common structure.
    
    Expected input structure:
    {
        "item": {
            "name": "Track Name",
            "artists": ["Artist"],
            "album": "Album",
            "album_art_url": "...",
            "duration_ms": 123456
        },
        "is_playing": true,
        "position_ms": 12345,
        "device": {"name": "Device Name"},
        "group_devices": ["Device 1", "Device 2"],
        "state": "PLAYING"
    }
    """
    item = payload.get("item") or {}
    device = payload.get("device") or {}
    
    # Extract artist names
    artists = item.get("artists") or []
    artist_str = None
    if artists:
        artist_names = []
        for artist in artists:
            if isinstance(artist, str):
                artist_names.append(artist)
            elif isinstance(artist, dict) and artist.get("name"):
                artist_names.append(artist["name"])
        artist_str = ", ".join(artist_names) if artist_names else None
    
    # Extract album info
    album_name = item.get("album")
    artwork_url = item.get("album_art_url") or item.get("albumArt") or item.get("album_art")
    
    # Extract device info
    group_devices = payload.get("group_devices") or []
    device_list = []
    if isinstance(group_devices, list):
        for dev in group_devices:
            if isinstance(dev, str):
                device_list.append({"name": dev})
            elif isinstance(dev, dict) and dev.get("name"):
                device_list.append({"name": dev["name"]})
    
    state = (payload.get("state") or "").upper()
    status_map = {
        "PLAYING": "playing",
        "PAUSED_PLAYBACK": "paused",
        "STOPPED": "stopped",
        "TRANSITIONING": "transitioning",
        "BUFFERING": "buffering",
    }
    status = status_map.get(state, state.lower() if state else "idle")
    
    return {
        "track": {
            "title": item.get("name"),
            "artist": artist_str,
            "album": album_name,
            "artwork_url": artwork_url,
            "duration_ms": item.get("duration_ms") or payload.get("duration_ms"),
        },
        "playback": {
            "is_playing": payload.get("is_playing", False),
            "progress_ms": payload.get("position_ms"),
            "timestamp": None,
            "status": status,
        },
        "device": {
            "name": device.get("name"),
            "type": "speaker",
            "group_devices": device_list if device_list else None,
        },
        "provider": "sonos",
    }


def normalize_payload(payload: Dict[str, Any], provider: str) -> Dict[str, Any]:
    """
    Normalize payload based on provider.
    
    Args:
        payload: Raw payload from provider
        provider: Provider name ("spotify" or "sonos")
    
    Returns:
        Normalized payload with common structure
    """
    if provider == "spotify":
        return normalize_spotify_payload(payload)
    elif provider == "sonos":
        return normalize_sonos_payload(payload)
    else:
        # Return as-is for unknown providers
        return payload
