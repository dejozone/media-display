# Normalized Now Playing Payload Structure

## Overview

All now-playing track information from different providers (Spotify, Sonos) is normalized into a common JSON structure before being sent to the client. This ensures consistent data handling across all providers.

## Normalized Payload Structure

```json
{
  "track": {
    "title": "Song Title",
    "artist": "Artist Name(s)",
    "album": "Album Name",
    "artwork_url": "https://...",
    "duration_ms": 180000
  },
  "playback": {
    "is_playing": true,
    "progress_ms": 45000,
    "timestamp": 1234567890,
    "status": "playing"
  },
  "device": {
    "name": "Device Name",
    "type": "speaker",
    "id": "device-id",
    "group_devices": [
      {"name": "Device 1"},
      {"name": "Device 2"}
    ]
  },
  "provider": "spotify"
}
```

## Field Descriptions

### `track` (object)
Contains track metadata.

- **`title`** (string | null): Track title or name
- **`artist`** (string | null): Comma-separated list of artist names
- **`album`** (string | null): Album name or podcast show name
- **`artwork_url`** (string | null): URL to album/track artwork image
- **`duration_ms`** (number | null): Total track duration in milliseconds

### `playback` (object)
Contains playback state information.

- **`is_playing`** (boolean): Whether track is currently playing
- **`progress_ms`** (number | null): Current playback position in milliseconds
- **`timestamp`** (number | null): Unix timestamp of the playback state
- **`status`** (string): Playback status - one of:
  - `"playing"` - Track is actively playing
  - `"paused"` - Track is paused
  - `"stopped"` - Playback stopped
  - `"transitioning"` - Changing tracks
  - `"buffering"` - Loading content
  - `"idle"` - No active playback

### `device` (object)
Contains device/speaker information.

- **`name`** (string | null): Primary device name
- **`type`** (string | null): Device type (e.g., "speaker", "Computer", "TV")
- **`id`** (string | null): Device identifier (Spotify only)
- **`group_devices`** (array | null): List of grouped devices (Sonos only)
  - Each device is an object with `name` property

### `provider` (string)
Source of the track information:
- `"spotify"` - Spotify API
- `"sonos"` - Sonos local network

## Null Handling

Any field may be `null` if the information is not available from the provider. Clients should handle null values gracefully:

```typescript
const title = payload.track.title ?? 'Unknown Track';
const artist = payload.track.artist ?? 'Unknown Artist';
```

## Provider Differences

### Spotify-Specific Fields
- `device.id` - Unique device identifier
- `device.type` - Detailed device type from Spotify
- `playback.timestamp` - Server-side timestamp

### Sonos-Specific Fields
- `device.group_devices` - Array of grouped speakers
- More frequent `null` values for metadata

## Migration from Old Structure

### Old Spotify Structure
```json
{
  "item": {
    "name": "Track",
    "artists": [{"name": "Artist"}],
    "album": {"name": "Album", "images": [...]}
  },
  "is_playing": true,
  "device": {"name": "Device"}
}
```

### Old Sonos Structure
```json
{
  "item": {
    "name": "Track",
    "artists": ["Artist"],
    "album": "Album",
    "album_art_url": "..."
  },
  "is_playing": true,
  "device": {"name": "Device"},
  "group_devices": ["Device 1", "Device 2"]
}
```

### New Normalized Structure (Both)
```json
{
  "track": {
    "title": "Track",
    "artist": "Artist",
    "album": "Album",
    "artwork_url": "..."
  },
  "playback": {
    "is_playing": true,
    "status": "playing"
  },
  "device": {
    "name": "Device",
    "group_devices": [{"name": "Device 1"}]
  },
  "provider": "spotify"
}
```

## Implementation Details

### Backend (Python)
The normalization happens in `events/lib/payload_normalizer.py`:

```python
from lib.payload_normalizer import normalize_payload

# In Spotify Manager
normalized = normalize_payload(spotify_data, "spotify")
await ws.send_json({"type": "now_playing", "data": normalized})

# In Sonos Manager
normalized = normalize_payload(sonos_data, "sonos")
await ws.send_json({"type": "now_playing", "data": normalized})
```

### Frontend (Flutter/Dart)
Parsing in `app/lib/src/features/home/home_page.dart`:

```dart
// Extract track info
final track = payload['track'];
final title = track?['title'] ?? 'Unknown Track';
final artist = track?['artist'] ?? 'Unknown Artist';
final album = track?['album'] ?? '';
final artworkUrl = track?['artwork_url'] ?? '';

// Extract playback info
final playback = payload['playback'];
final isPlaying = playback?['is_playing'] ?? false;
final status = playback?['status'] ?? 'idle';

// Extract device info
final device = payload['device'];
final deviceName = device?['name'] ?? '';
final groupDevices = device?['group_devices'] as List?;
```

## Benefits

1. **Consistency**: Single parsing logic for all providers
2. **Maintainability**: Changes to one provider don't affect others
3. **Type Safety**: Predictable field types and structure
4. **Extensibility**: Easy to add new providers
5. **Null Safety**: Explicit null handling for missing data
6. **Documentation**: Clear contract between backend and frontend

## Testing

Run the normalization tests:

```bash
cd events
python3 test/test_payload_normalizer.py
```

This validates:
- Spotify payload normalization
- Sonos payload normalization
- Null value handling
- Field mappings
- Data type consistency
