import 'dart:async';
import 'dart:math';
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
  bool _tokenRequestPending = false;
  DateTime? _lastCooldownTime;
  SpotifyApiClient? _apiClient;
  int _consecutive401Errors = 0;
  static const int _max401BeforeStop = 3;
  int _retryAttempts = 0;
  final Random _random = Random();

  @override
  SpotifyDirectState build() {
    final env = ref.read(envConfigProvider);
    _apiClient = SpotifyApiClient(
      sslVerify: env.directSpotifyApiSslVerify,
      baseUrl: env.directSpotifyApiBaseUrl,
      timeoutSec: env.directSpotifyTimeoutSec,
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
    debugPrint('[SPOTIFY] Token updated, expiresAt=$expiresAt');

    // Cancel any existing refresh timer before scheduling a new one
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;

    // Reset pending flag - we got the token
    _tokenRequestPending = false;

    state = state.copyWith(
      accessToken: accessToken,
      tokenExpiresAt: expiresAt,
      lastTokenRefreshTime: DateTime.now(),
    );

    // Reset 401 error counter on fresh token
    _consecutive401Errors = 0;

    // Schedule proactive token refresh before expiry
    _scheduleTokenRefresh(expiresAt);

    // Start direct polling if in fallback/offline mode (trying to recover)
    // or if already in direct mode but timer was cancelled (waiting for token)
    // Do NOT start if idle - that means polling was intentionally stopped by orchestrator
    if (state.mode == SpotifyPollingMode.fallback ||
        state.mode == SpotifyPollingMode.offline) {
      _startDirectPolling();
    } else if (state.mode == SpotifyPollingMode.direct && _pollTimer == null) {
      // Poll timer was cancelled (e.g., due to 401), restart it
      // debugPrint('[SPOTIFY] Restarting poll after token update');
      _poll();
    }
    // If mode is idle, do nothing - orchestrator will call startDirectPolling() if needed
  }

  /// Schedule fallback token refresh before it expires
  /// The server should proactively send refreshed tokens ~5 minutes before expiry.
  /// This client-side timer is a FALLBACK in case the server doesn't refresh.
  void _scheduleTokenRefresh(int expiresAt) {
    // Cancel any existing timer first
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresIn = expiresAt - now;

    if (expiresIn <= 0) {
      debugPrint(
          '[SPOTIFY] Token already expired, requesting refresh immediately');
      _requestTokenRefresh();
      return;
    }

    // The server should proactively send a refreshed token ~5 minutes before expiry.
    // Schedule client-side refresh as a FALLBACK 1 minute before expiry,
    // giving the server plenty of time to send the refresh first.
    const fallbackBuffer = 60; // 1 minute before expiry as fallback
    final refreshIn = expiresIn - fallbackBuffer;

    if (refreshIn <= 0) {
      // Token expires in less than 1 minute, refresh now
      debugPrint(
          '[SPOTIFY] Token expiring very soon, requesting refresh immediately');
      _requestTokenRefresh();
      return;
    }

    debugPrint(
        '[SPOTIFY] Scheduling fallback token refresh in ${refreshIn}s (token expires in ${expiresIn}s)');
    _tokenRefreshTimer = Timer(Duration(seconds: refreshIn), () {
      // Only request if token hasn't been refreshed by server
      final currentExpiresAt = state.tokenExpiresAt;
      if (currentExpiresAt != null && currentExpiresAt <= expiresAt) {
        debugPrint(
            '[SPOTIFY] Fallback token refresh timer fired - server did not refresh');
        _requestTokenRefresh();
      } else {
        debugPrint(
            '[SPOTIFY] Fallback timer fired but token was already refreshed by server');
      }
    });
  }

  /// Check if token is expired or about to expire
  bool _isTokenExpired() {
    final expiresAt = state.tokenExpiresAt;
    if (expiresAt == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= expiresAt - 30; // 30s buffer
  }

  int _computeBackoffWithJitter(
    int baseSeconds,
    int attempt, {
    int maxSeconds = 120,
    double jitterRatio = 0.2,
  }) {
    final scaled = (baseSeconds * pow(2, attempt)).toInt();
    final clamped = scaled > maxSeconds ? maxSeconds : scaled;
    final jitterWindow = (clamped * jitterRatio).toInt();
    if (jitterWindow <= 0) return clamped;

    final jitter = _random.nextInt(jitterWindow + 1); // 0..window
    final withJitter = clamped + jitter;
    if (withJitter < baseSeconds) return baseSeconds;
    if (withJitter > maxSeconds) return maxSeconds;
    return withJitter;
  }

  /// Starts direct Spotify API polling
  void startDirectPolling() {
    // Set mode to direct even if no token yet
    // When token arrives, updateToken() will start actual polling
    if (state.accessToken == null) {
      debugPrint('[SPOTIFY] Direct polling requested - waiting for token');
      _pollTimer?.cancel();
      _retryTimer?.cancel();
      state = state.copyWith(
        mode: SpotifyPollingMode.direct,
        error: null,
      );
      return;
    }
    _startDirectPolling();
  }

  /// Probe Spotify API to check if service is healthy
  /// Returns true if API responds successfully (HTTP < 300)
  /// This does NOT affect polling state or UI - it's just a health check
  Future<bool> probeService() async {
    final token = state.accessToken;
    if (token == null) {
      debugPrint('[SPOTIFY] Probe failed: no access token');
      return false;
    }

    if (_isTokenExpired()) {
      debugPrint('[SPOTIFY] Probe failed: token expired');
      return false;
    }

    try {
      // Make a single API call to check if Spotify is reachable
      await _apiClient!.getCurrentPlayback(token);
      // Any response (including null for 204) is considered healthy
      debugPrint('[SPOTIFY] Probe successful');
      return true;
    } on SpotifyApiException catch (e) {
      debugPrint('[SPOTIFY] Probe failed: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[SPOTIFY] Probe failed: $e');
      return false;
    }
  }

  /// Stops all polling and cancels all timers
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _tokenCheckTimer?.cancel();
    _tokenCheckTimer = null;
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;
    _tokenRequestPending = false;
    _retryAttempts = 0;
    state = state.copyWith(
      mode: SpotifyPollingMode.idle,
      error: null,
    );
    _fallbackStartTime = null;
    _lastCooldownTime = null;
    debugPrint('[SPOTIFY] Polling stopped (all timers cancelled)');
  }

  void _startDirectPolling() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _fallbackStartTime = null;
    _retryAttempts = 0;
    _lastCooldownTime = null;

    state = state.copyWith(
      mode: SpotifyPollingMode.direct,
      error: null,
    );

    debugPrint('[SPOTIFY] Switched to direct mode');

    // Only start polling if we have a valid token
    // If no token yet, updateToken() will call _poll() when token arrives
    if (state.accessToken != null && !_isTokenExpired()) {
      _poll();
    }
  }

  Future<void> _poll() async {
    // Cancel both timers to prevent overlapping polls
    _pollTimer?.cancel();
    _retryTimer?.cancel();

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
      }

      // Reset 401 counter on success
      _consecutive401Errors = 0;

      // Schedule next poll (cancel any stray retry timer first)
      _retryTimer?.cancel();
      final env = ref.read(envConfigProvider);
      _pollTimer = Timer(
        Duration(seconds: env.directSpotifyPollIntervalSec),
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
          Duration(seconds: env.directSpotifyRetryIntervalSec),
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
    final env = ref.read(envConfigProvider);
    final now = DateTime.now();

    // Check if we've been failing for longer than retry window (0 = unlimited)
    _fallbackStartTime ??= now;

    final failureDuration = now.difference(_fallbackStartTime!);
    final retryWindowSec = env.directSpotifyRetryWindowSec;
    final windowExceeded =
        retryWindowSec > 0 && failureDuration.inSeconds >= retryWindowSec;
    if (windowExceeded) {
      // debugPrint(
      //     '[SPOTIFY] Direct poll failed for ${failureDuration.inSeconds}s (retry 3/3) - entering fallback mode');
      _enterFallbackMode(errorMessage);
      return;
    }

    // Retry after interval
    // debugPrint(
    //     '[SPOTIFY] Direct poll failed: $errorMessage (retry $_consecutiveFailures)');
    state = state.copyWith(error: errorMessage);

    // Cancel both timers to prevent overlapping
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _pollTimer = Timer(
      Duration(seconds: env.directSpotifyRetryIntervalSec),
      _poll,
    );
  }

  void _enterFallbackMode(String reason) {
    _pollTimer?.cancel();
    state = state.copyWith(
      mode: SpotifyPollingMode.fallback,
      error: reason,
    );

    _fallbackStartTime ??= DateTime.now();
    _retryAttempts = 0;
    _lastCooldownTime = null;

    // debugPrint('[SPOTIFY] Switched to fallback mode: $reason');

    // Start background retry loop
    _startBackgroundRetry();
  }

  void _startBackgroundRetry() {
    // Cancel both timers to prevent overlapping
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _scheduleRetryAttempt();
  }

  void _scheduleRetryAttempt({int? delaySeconds}) {
    _retryTimer?.cancel();

    final env = ref.read(envConfigProvider);
    final base = env.directSpotifyRetryIntervalSec;
    final maxBackoff = env.directSpotifyRetryCooldownSec > 0
        ? max(env.directSpotifyRetryCooldownSec, base * 4)
        : base * 4;
    final delay = delaySeconds ??
        _computeBackoffWithJitter(
          base,
          _retryAttempts,
          maxSeconds: maxBackoff,
        );

    _retryTimer = Timer(Duration(seconds: delay), _attemptDirectRetry);
  }

  Future<void> _attemptDirectRetry() async {
    if (state.mode != SpotifyPollingMode.fallback) {
      _retryTimer?.cancel();
      return;
    }

    final token = state.accessToken;
    final env = ref.read(envConfigProvider);
    final now = DateTime.now();
    final retryWindowSec = env.directSpotifyRetryWindowSec;

    if (_lastCooldownTime != null) {
      final sinceLastCooldown = now.difference(_lastCooldownTime!).inSeconds;
      final cooldownSec = env.directSpotifyRetryCooldownSec;
      if (cooldownSec > 0 && sinceLastCooldown < cooldownSec) {
        // Still cooling down; try again when cooldown ends
        _scheduleRetryAttempt(delaySeconds: cooldownSec - sinceLastCooldown);
        return;
      }
      _lastCooldownTime = null;
    }

    if (token == null) {
      _scheduleRetryAttempt();
      return;
    }

    _fallbackStartTime ??= now;

    try {
      final response = await _apiClient!.getCurrentPlayback(token);
      // Success! Switch back to direct mode
      _fallbackStartTime = null;
      _retryAttempts = 0;
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
      _retryAttempts += 1;

      // If retry window exceeded (0 = unlimited), trigger cooldown or stop retries
      if (_fallbackStartTime != null) {
        final failureDuration = now.difference(_fallbackStartTime!);
        final windowExceeded =
            retryWindowSec > 0 && failureDuration.inSeconds >= retryWindowSec;
        if (windowExceeded) {
          final cooldownSec = env.directSpotifyRetryCooldownSec;
          if (cooldownSec <= 0) {
            // No cooldown configured: stop retrying to avoid noisy fetch errors
            _retryTimer?.cancel();
            _retryAttempts = 0;
            state = state.copyWith(mode: SpotifyPollingMode.offline);
            return;
          }

          // Enter cooldown; timer will skip polls until cooldown elapses
          _lastCooldownTime = now;
          _fallbackStartTime = now; // Reset for next window
          _retryAttempts = 0;
          _scheduleRetryAttempt(delaySeconds: cooldownSec);
          return;
        }
      }
    }

    if (state.mode == SpotifyPollingMode.fallback) {
      _scheduleRetryAttempt();
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
    // Prevent duplicate token requests
    if (_tokenRequestPending) {
      debugPrint('[SPOTIFY] Token request already pending, skipping');
      return;
    }
    _tokenRequestPending = true;

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
