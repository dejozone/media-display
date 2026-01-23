#!/usr/bin/env python3
"""
Test payload normalization for Spotify and Sonos
"""
import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from lib.payload_normalizer import normalize_payload


def test_spotify_normalization():
    """Test Spotify payload normalization"""
    spotify_payload = {
        "item": {
            "name": "Test Track",
            "artists": [
                {"name": "Artist 1"},
                {"name": "Artist 2"}
            ],
            "album": {
                "name": "Test Album",
                "images": [
                    {"url": "https://example.com/image.jpg"}
                ]
            },
            "duration_ms": 180000
        },
        "is_playing": True,
        "progress_ms": 45000,
        "device": {
            "name": "My Computer",
            "type": "Computer",
            "id": "device123"
        },
        "timestamp": 1234567890
    }
    
    normalized = normalize_payload(spotify_payload, "spotify")
    
    print("Spotify Normalized Payload:")
    print(f"  Track Title: {normalized['track']['title']}")
    print(f"  Artist: {normalized['track']['artist']}")
    print(f"  Album: {normalized['track']['album']}")
    print(f"  Artwork URL: {normalized['track']['artwork_url']}")
    print(f"  Duration: {normalized['track']['duration_ms']}ms")
    print(f"  Is Playing: {normalized['playback']['is_playing']}")
    print(f"  Progress: {normalized['playback']['progress_ms']}ms")
    print(f"  Status: {normalized['playback']['status']}")
    print(f"  Device Name: {normalized['device']['name']}")
    print(f"  Device Type: {normalized['device']['type']}")
    print(f"  Provider: {normalized['provider']}")
    print()
    
    assert normalized['track']['title'] == "Test Track"
    assert normalized['track']['artist'] == "Artist 1, Artist 2"
    assert normalized['track']['album'] == "Test Album"
    assert normalized['playback']['is_playing'] is True
    assert normalized['provider'] == "spotify"
    print("✅ Spotify normalization test passed!")
    print()


def test_sonos_normalization():
    """Test Sonos payload normalization"""
    sonos_payload = {
        "item": {
            "name": "Another Track",
            "artists": ["Artist A", "Artist B"],
            "album": "Another Album",
            "album_art_url": "http://192.168.1.100:1400/art.jpg",
            "duration_ms": 240000
        },
        "is_playing": True,
        "position_ms": 60000,
        "device": {
            "name": "Living Room"
        },
        "group_devices": ["Living Room", "Kitchen", "Bedroom"],
        "state": "PLAYING"
    }
    
    normalized = normalize_payload(sonos_payload, "sonos")
    
    print("Sonos Normalized Payload:")
    print(f"  Track Title: {normalized['track']['title']}")
    print(f"  Artist: {normalized['track']['artist']}")
    print(f"  Album: {normalized['track']['album']}")
    print(f"  Artwork URL: {normalized['track']['artwork_url']}")
    print(f"  Duration: {normalized['track']['duration_ms']}ms")
    print(f"  Is Playing: {normalized['playback']['is_playing']}")
    print(f"  Progress: {normalized['playback']['progress_ms']}ms")
    print(f"  Status: {normalized['playback']['status']}")
    print(f"  Device Name: {normalized['device']['name']}")
    print(f"  Device Type: {normalized['device']['type']}")
    print(f"  Group Devices: {[d['name'] for d in normalized['device']['group_devices']]}")
    print(f"  Provider: {normalized['provider']}")
    print()
    
    assert normalized['track']['title'] == "Another Track"
    assert normalized['track']['artist'] == "Artist A, Artist B"
    assert normalized['track']['album'] == "Another Album"
    assert normalized['playback']['is_playing'] is True
    assert normalized['playback']['status'] == "playing"
    assert normalized['provider'] == "sonos"
    assert len(normalized['device']['group_devices']) == 3
    print("✅ Sonos normalization test passed!")
    print()


def test_null_values():
    """Test that missing fields are set to None"""
    minimal_spotify = {
        "item": {},
        "is_playing": False
    }
    
    normalized = normalize_payload(minimal_spotify, "spotify")
    
    print("Minimal Spotify Payload Normalization:")
    print(f"  Track Title: {normalized['track']['title']}")
    print(f"  Artist: {normalized['track']['artist']}")
    print(f"  Album: {normalized['track']['album']}")
    print(f"  Artwork URL: {normalized['track']['artwork_url']}")
    print(f"  Is Playing: {normalized['playback']['is_playing']}")
    print()
    
    assert normalized['track']['title'] is None
    assert normalized['track']['artist'] is None
    assert normalized['track']['album'] is None
    assert normalized['track']['artwork_url'] is None
    assert normalized['playback']['is_playing'] is False
    print("✅ Null values test passed!")
    print()


if __name__ == "__main__":
    print("=" * 60)
    print("Testing Payload Normalization")
    print("=" * 60)
    print()
    
    try:
        test_spotify_normalization()
        test_sonos_normalization()
        test_null_values()
        print("=" * 60)
        print("✅ All tests passed!")
        print("=" * 60)
    except AssertionError as e:
        print(f"❌ Test failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
