import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/spotify_api_client.dart';

enum SpotifyPollingMode {
  idle,
  direct,
  fallback,
  offline,
}

class SpotifyDirectState {
  const SpotifyDirectState({
    this.mode = SpotifyPollingMode.idle,
    this.payload,
    this.error,
    this.accessToken,
    this.tokenExpiresAt,
    this.lastTokenRefreshTime,
  });

  final SpotifyPollingMode mode;
  final Map<String, dynamic>? payload;
  final String? error;
  final String? accessToken;
  final int? tokenExpiresAt; // Unix timestamp in seconds
  final DateTime? lastTokenRefreshTime;

  SpotifyDirectState copyWith({
    SpotifyPollingMode? mode,
    Map<String, dynamic>? payload,
    String? error,
    String? accessToken,
    int? tokenExpiresAt,
    DateTime? lastTokenRefreshTime,
  }) {
    return SpotifyDirectState(
      mode: mode ?? this.mode,
      payload: payload ?? this.payload,
      error: error,
      accessToken: accessToken ?? this.accessToken,
      tokenExpiresAt: tokenExpiresAt ?? this.tokenExpiresAt,
      lastTokenRefreshTime: lastTokenRefreshTime ?? this.lastTokenRefreshTime,
    );
  }
}

class SpotifyDirectNotifier extends Notifier<SpotifyDirectState> {
  Timer? _pollTimer;
  Timer? _tokenCheckTimer;
  Timer? _retryTimer;
  Timer? _tokenRefreshTimer;
  DateTime? _fallbackStartTime;
  DateTime? _lastCooldownTime;
  SpotifyApiClient? _apiClient;
  int _consecutiveFailures = 0;
  int _consecutive401Errors = 0;
  static const int _max401BeforeStop = 3;

  @override
  SpotifyDirectState build() {
    final env = ref.read(envConfigProvider);
    _apiClient = SpotifyApiClient(
      sslVerify: env.spotifyDirectApiSslVerify,
      baseUrl: env.spotifyDirectApiBaseUrl,
    );

    ref.onDispose(() {
      _pollTimer?.cancel();
      _tokenCheckTimer?.cancel();
      _retryTimer?.cancel();
      _tokenRefreshTimer?.cancel();
      _apiClient?.dispose();
    });

    // Start token expiry check timer (every 30s)
    _tokenCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkTokenExpiry(),
    );

    return const SpotifyDirectState();
  }

  /// Updates the access token received from WebSocket
  void updateToken(String accessToken, int expiresAt) {
    state = state.copyWith(
      accessToken: accessToken,
      tokenExpiresAt: expiresAt,
      lastTokenRefreshTime: DateTime.now(),
    );

    // Reset 401 error counter on fresh token
    _consecutive401Errors = 0;

    // Schedule proactive token refresh before expiry
    _scheduleTokenRefresh(expiresAt);

    // Start direct polling if idle, or retry if in fallback/offline mode
    if (state.mode == SpotifyPollingMode.idle ||
        state.mode == SpotifyPollingMode.fallback ||
        state.mode == SpotifyPollingMode.offline) {
      _startDirectPolling();
    } else if (state.mode == SpotifyPollingMode.direct && _pollTimer == null) {
      // Poll timer was cancelled (e.g., due to 401), restart it
      // debugPrint('[SPOTIFY] Restarting poll after token update');
      _poll();
    }
  }

  /// Schedule proactive token refresh before it expires
  void _scheduleTokenRefresh(int expiresAt) {
    _tokenRefreshTimer?.cancel();

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Refresh 2 minutes before expiry to have buffer
    final refreshInSec = (expiresAt - now) - 120;

    if (refreshInSec > 0) {
      // debugPrint('[SPOTIFY] Scheduling token refresh in ${refreshInSec}s');
      _tokenRefreshTimer = Timer(
        Duration(seconds: refreshInSec),
        () {
            // debugPrint('[SPOTIFY] Proactive token refresh triggered');
          _requestTokenRefresh();
        },
      );
    }
  }

  /// Check if token is expired or about to expire
  bool _isTokenExpired() {
    final expiresAt = state.tokenExpiresAt;
    if (expiresAt == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= expiresAt - 30; // 30s buffer
  }

  /// Starts direct Spotify API polling
  void startDirectPolling() {
    if (state.accessToken == null) {
      // debugPrint('[SPOTIFY] Cannot start direct polling: no access token');
      return;
    }
    _startDirectPolling();
  }

  /// Stops all polling
  void stopPolling() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    state = state.copyWith(
      mode: SpotifyPollingMode.idle,
      error: null,
    );
    _consecutiveFailures = 0;
    _fallbackStartTime = null;
    debugPrint('[SPOTIFY] Polling stopped');
  }

  void _startDirectPolling() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _consecutiveFailures = 0;
    _fallbackStartTime = null;

    state = state.copyWith(
      mode: SpotifyPollingMode.direct,
      error: null,
    );

    debugPrint('[SPOTIFY] Switched to direct mode');
    _poll();
  }

  Future<void> _poll() async {
    if (state.mode != SpotifyPollingMode.direct) return;

    final token = state.accessToken;
    if (token == null) {
      // debugPrint('[SPOTIFY] No access token available for polling');
      _enterFallbackMode('No access token');
      return;
    }

    // Check if token is expired before making request
    if (_isTokenExpired()) {
      // debugPrint('[SPOTIFY] Token expired before poll - requesting refresh');
      _requestTokenRefresh();
      // Schedule retry after short delay (token refresh should arrive)
      _pollTimer?.cancel();
      _pollTimer = Timer(const Duration(seconds: 5), _poll);
      return;
    }

    try {
      final response = await _apiClient!.getCurrentPlayback(token);

      if (response == null) {
        // No active playback (204 response) - set a "stopped" payload
        state = state.copyWith(
          payload: _createStoppedPayload(),
          error: null,
        );
      } else {
        // Normalize the response
        final normalized = _normalizeSpotifyResponse(response);
        state = state.copyWith(
          payload: normalized,
          error: null,
        );
        _consecutiveFailures = 0;
      }

      // Reset 401 counter on success
      _consecutive401Errors = 0;

      // Schedule next poll
      final env = ref.read(envConfigProvider);
      _pollTimer = Timer(
        Duration(seconds: env.spotifyDirectPollIntervalSec),
        _poll,
      );
    } on SpotifyApiException catch (e) {
      if (e.isAuthError) {
        _consecutive401Errors++;
        // debugPrint(
        //     '[SPOTIFY] Direct poll failed: 401 ($_consecutive401Errors/$_max401BeforeStop)');

        // Request token refresh
        _requestTokenRefresh();

        // If too many consecutive 401s, enter fallback mode
        if (_consecutive401Errors >= _max401BeforeStop) {
          // debugPrint('[SPOTIFY] Too many 401 errors - entering fallback mode');
          _consecutive401Errors = 0;
          _enterFallbackMode('Authentication failed repeatedly');
          return;
        }

        // Keep trying with retry interval (don't stop completely)
        _pollTimer?.cancel();
        final env = ref.read(envConfigProvider);
        _pollTimer = Timer(
          Duration(seconds: env.spotifyDirectRetryIntervalSec),
          _poll,
        );
        return;
      }

      _handlePollFailure(e.message);
    } catch (e) {
      _handlePollFailure(e.toString());
    }
  }

  void _handlePollFailure(String errorMessage) {
    _consecutiveFailures++;
    final env = ref.read(envConfigProvider);
    final now = DateTime.now();

    // Check if we've been failing for longer than retry window
    if (_fallbackStartTime == null) {
      _fallbackStartTime = now;
    }

    final failureDuration = now.difference(_fallbackStartTime!);
    if (failureDuration.inSeconds >= env.spotifyDirectRetryWindowSec) {
      // debugPrint(
      //     '[SPOTIFY] Direct poll failed for ${failureDuration.inSeconds}s (retry 3/3) - entering fallback mode');
      _enterFallbackMode(errorMessage);
      return;
    }

    // Retry after interval
    // debugPrint(
    //     '[SPOTIFY] Direct poll failed: $errorMessage (retry $_consecutiveFailures)');
    state = state.copyWith(error: errorMessage);

    _pollTimer?.cancel();
    _pollTimer = Timer(
      Duration(seconds: env.spotifyDirectRetryIntervalSec),
      _poll,
    );
  }

  void _enterFallbackMode(String reason) {
    _pollTimer?.cancel();
    state = state.copyWith(
      mode: SpotifyPollingMode.fallback,
      error: reason,
    );

    // debugPrint('[SPOTIFY] Switched to fallback mode: $reason');

    // Start background retry loop
    _startBackgroundRetry();
  }

  void _startBackgroundRetry() {
    _retryTimer?.cancel();

    final env = ref.read(envConfigProvider);
    _retryTimer = Timer.periodic(
      Duration(seconds: env.spotifyDirectRetryIntervalSec),
      (_) => _attemptDirectRetry(),
    );
  }

  Future<void> _attemptDirectRetry() async {
    if (state.mode != SpotifyPollingMode.fallback) {
      _retryTimer?.cancel();
      return;
    }

    final token = state.accessToken;
    if (token == null) return;

    final env = ref.read(envConfigProvider);
    final now = DateTime.now();

    // Check if we need cooldown
    if (_lastCooldownTime != null) {
      final sinceLastCooldown = now.difference(_lastCooldownTime!);
      if (sinceLastCooldown.inSeconds < env.spotifyDirectCooldownSec) {
        return; // Still in cooldown
      }
      _lastCooldownTime = null;
    }

    try {
      final response = await _apiClient!.getCurrentPlayback(token);
      // Success! Switch back to direct mode
      // debugPrint(
      //     '[SPOTIFY] Background retry succeeded - switching to direct mode');
      _consecutiveFailures = 0;
      _fallbackStartTime = null;
      _retryTimer?.cancel();

      if (response != null) {
        final normalized = _normalizeSpotifyResponse(response);
        state = state.copyWith(
          mode: SpotifyPollingMode.direct,
          payload: normalized,
          error: null,
        );
      } else {
        state = state.copyWith(
          mode: SpotifyPollingMode.direct,
          payload: null,
          error: null,
        );
      }

      _poll(); // Start regular polling
    } catch (e) {
      _consecutiveFailures++;

      // If retry window exceeded, trigger cooldown
      if (_fallbackStartTime != null) {
        final failureDuration = now.difference(_fallbackStartTime!);
        if (failureDuration.inSeconds >= env.spotifyDirectRetryWindowSec) {
          // debugPrint(
          //     '[SPOTIFY] Retry window exhausted - entering cooldown (${env.spotifyDirectCooldownSec}s)');
          _lastCooldownTime = now;
          _fallbackStartTime = now; // Reset for next window
          _consecutiveFailures = 0;
        }
      }
    }
  }

  void _checkTokenExpiry() {
    final expiresAt = state.tokenExpiresAt;
    if (expiresAt == null) return;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timeUntilExpiry = expiresAt - now;

    // If token expires in <60s and we haven't refreshed recently
    if (timeUntilExpiry < 60) {
      final lastRefresh = state.lastTokenRefreshTime;
      if (lastRefresh == null ||
          DateTime.now().difference(lastRefresh).inSeconds > 60) {
        // debugPrint(
        //     '[SPOTIFY] Token expires in ${timeUntilExpiry}s - requesting refresh');
        _requestTokenRefresh();
      }
    }
  }

  void _requestTokenRefresh() {
    // This will be handled by events_ws_service sending a config message
    // The callback is set up when the service is initialized
    ref.read(spotifyTokenRefreshCallbackProvider).callback?.call();
  }

  /// Creates a payload representing "stopped" state (no active playback)
  Map<String, dynamic> _createStoppedPayload() {
    return {
      'track': {
        'title': '',
        'artist': '',
        'album': '',
        'artwork_url': '',
        'duration_ms': 0,
      },
      'playback': {
        'is_playing': false,
        'progress_ms': 0,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'stopped',
      },
      'device': {
        'name': '',
        'type': '',
        'group_devices': <Map<String, dynamic>>[],
      },
      'provider': 'spotify',
    };
  }

  Map<String, dynamic> _normalizeSpotifyResponse(
      Map<String, dynamic> response) {
    final item = response['item'] as Map<String, dynamic>?;
    final device = response['device'] as Map<String, dynamic>?;
    final isPlaying = response['is_playing'] as bool? ?? false;
    final progressMs = response['progress_ms'] as int? ?? 0;
    final timestamp = response['timestamp'] as int? ?? 0;

    final artists = (item?['artists'] as List?)
        ?.map((a) => (a as Map)['name'] as String?)
        .whereType<String>()
        .join(', ');

    final images = (item?['album'] as Map?)?['images'] as List?;
    final artworkUrl = images?.isNotEmpty == true
        ? ((images!.first as Map)['url'] as String?)
        : null;

    return {
      'track': {
        'title': item?['name'] as String? ?? '',
        'artist': artists ?? '',
        'album': (item?['album'] as Map?)?['name'] as String? ?? '',
        'artwork_url': artworkUrl ?? '',
        'duration_ms': item?['duration_ms'] as int? ?? 0,
      },
      'playback': {
        'is_playing': isPlaying,
        'progress_ms': progressMs,
        'timestamp': timestamp,
        'status': isPlaying ? 'playing' : 'paused',
      },
      'device': {
        'name': device?['name'] as String? ?? '',
        'type': device?['type'] as String? ?? 'speaker',
        'group_devices': <Map<String, dynamic>>[], // Spotify doesn't group
      },
      'provider': 'spotify',
    };
  }
}

final spotifyDirectProvider =
    NotifierProvider<SpotifyDirectNotifier, SpotifyDirectState>(
  SpotifyDirectNotifier.new,
);

// Callback provider for requesting token refresh from events_ws_service
class SpotifyTokenRefreshCallback {
  VoidCallback? callback;
}

final spotifyTokenRefreshCallbackProvider =
    Provider<SpotifyTokenRefreshCallback>((ref) {
  return SpotifyTokenRefreshCallback();
});
