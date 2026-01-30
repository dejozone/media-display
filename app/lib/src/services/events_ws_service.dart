import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/api_client.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/user_service.dart';
import 'package:media_display/src/services/ws_retry_policy.dart';
import 'package:media_display/src/services/ws_ssl_override.dart'
    if (dart.library.io) 'package:media_display/src/services/ws_ssl_override_io.dart';
import 'package:media_display/src/services/spotify_direct_service.dart';
import 'package:media_display/src/services/service_priority_manager.dart';

/// Timestamped debug print for correlation with server logs
void _log(String message) {
  final now = DateTime.now();
  final mo = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  final h = now.hour.toString().padLeft(2, '0');
  final m = now.minute.toString().padLeft(2, '0');
  final s = now.second.toString().padLeft(2, '0');
  final ms = now.millisecond.toString().padLeft(3, '0');
  debugPrint('[$mo-$d $h:$m:$s.$ms] $message');
}

class NowPlayingState {
  const NowPlayingState({
    this.provider,
    this.payload,
    this.error,
    this.connected = false,
    this.mode = SpotifyPollingMode.idle,
    this.wsRetrying = false,
    this.wsInCooldown = false,
  });
  final String? provider;
  final Map<String, dynamic>? payload;
  final String? error;
  final bool connected;
  final SpotifyPollingMode mode;
  final bool wsRetrying;
  final bool wsInCooldown;
}

/// Callback type for service status updates
typedef ServiceStatusCallback = void Function(Map<String, dynamic> statusData);

class EventsWsNotifier extends Notifier<NowPlayingState> {
  WebSocketChannel? _channel;
  Timer? _retryTimer;
  Timer? _configRetryTimer;
  late final WsRetryPolicy _retryPolicy;
  bool _connecting = false;
  bool _connectionConfirmed = false;
  bool _initialConfigSent = false; // Track if initial config sent after connect
  Map<String, dynamic>? _lastSettings;
  bool _useDirectPolling = false;

  /// Update the cached settings. Call this before sendConfig when settings change.
  void updateCachedSettings(Map<String, dynamic> settings) {
    _lastSettings = settings;
  }

  bool _tokenRequested = false;
  DateTime? _lastTokenRequestTime;
  bool _wsTokenReceived =
      false; // Track if WS has sent a token (prefer WS over REST)
  bool _lastSpotifyEnabled = false; // Track previous Spotify enabled state

  /// Callback for service status updates (set by orchestrator)
  ServiceStatusCallback? onServiceStatus;

  @override
  NowPlayingState build() {
    final env = ref.read(envConfigProvider);
    _retryPolicy = WsRetryPolicy(
      interval: Duration(milliseconds: env.wsRetryIntervalMs),
      activeWindow: Duration(seconds: env.wsRetryActiveSeconds),
      cooldown: Duration(seconds: env.wsRetryCooldownSeconds),
      maxTotal: Duration(seconds: env.wsRetryMaxTotalSeconds),
    );

    // Set up token refresh callback for spotify_direct_service
    ref.read(spotifyTokenRefreshCallbackProvider).callback = () {
      _requestTokenRefresh();
    };

    ref.onDispose(() {
      _retryTimer?.cancel();
      _configRetryTimer?.cancel();
      _channel?.sink.close();
    });

    // React to auth changes and connect/disconnect accordingly.
    ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (next.isAuthenticated && (prev == null || !prev.isAuthenticated)) {
        _refreshAndMaybeConnect(next);
      }
      if (!next.isAuthenticated) {
        // Stop direct polling on logout
        ref.read(spotifyDirectProvider.notifier).stopPolling();
        _disconnect();
      }
    });

    final auth = ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      _refreshAndMaybeConnect(auth);
    }

    return const NowPlayingState();
  }

  Future<void> _connect(AuthState auth,
      {String caller = 'unknown', bool skipSendConfig = false}) async {
    if (!auth.isAuthenticated) return;

    // CRITICAL: Set _connecting FIRST to prevent race conditions
    // Check and set atomically using a local flag
    if (_connecting) {
      return;
    }
    _connecting = true;

    // If already connected, don't reconnect - just send config (unless skipped)
    if (_channel != null && _connectionConfirmed) {
      _connecting = false; // Reset since we're not actually connecting
      if (!skipSendConfig) {
        await sendConfig();
      }
      return;
    }

    try {
      // Ensure we don't stack multiple channels; close any existing one first.
      _disconnect(scheduleRetry: false);
      final env = ref.read(envConfigProvider);
      _retryTimer?.cancel();
      final uri = Uri.parse('${env.eventsWsUrl}?token=${auth.token}');

      WebSocketChannel? channel;
      try {
        await withInsecureWs(() async {
          channel = WebSocketChannel.connect(uri);
        }, allowInsecure: !env.eventsWsSslVerify);

        // Wait for the WebSocket connection to be established
        // This throws if connection fails
        await channel!.ready;
        _channel = channel;
      } catch (e) {
        // _log('[WS] Unable to connect to server, will retry...');
        state = NowPlayingState(
          error: 'Unable to connect to server',
          connected: false,
          provider: state.provider,
          payload: state.payload,
          mode: ref.read(spotifyDirectProvider).mode,
          wsRetrying: _retryPolicy.isRetrying,
          wsInCooldown: _retryPolicy.inCooldown,
        );
        _channel = null;
        _scheduleRetry();

        // Try to start direct polling - either with cached token or fetch via REST API
        final spotifyEnabled = _lastSettings?['spotify_enabled'] == true;
        if (spotifyEnabled) {
          await _tryStartDirectPollingWithFallback();
        }
        return;
      }

      // Don't reset retry policy or mark connected yet - wait for 'ready' message
      _connectionConfirmed = false;

      // Send current service enablement to the server (unless skipped by caller)
      if (!skipSendConfig) {
        await sendConfig();
      }

      _channel?.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            final type = data['type'];
            if (type == 'now_playing') {
              final provider = data['provider'] as String?;

              // Process if:
              // 1. Not in direct polling mode (use all backend data), OR
              // 2. This is Sonos data (Sonos can only come via WebSocket, never from direct polling)
              final isSonosData = provider == 'sonos';
              if (!_useDirectPolling || isSonosData) {
                final payload = (data['data'] as Map?)?.cast<String, dynamic>();
                final directMode = ref.read(spotifyDirectProvider).mode;
                state = NowPlayingState(
                  provider: provider,
                  payload: payload,
                  connected: true,
                  mode: directMode,
                  wsRetrying: false,
                  wsInCooldown: false,
                );
              }
            } else if (type == 'spotify_token') {
              final accessToken = data['access_token'] as String?;
              final expiresAt = data['expires_at'];
              if (accessToken != null && expiresAt != null) {
                int expiresAtInt;
                if (expiresAt is int) {
                  expiresAtInt = expiresAt;
                } else if (expiresAt is double) {
                  expiresAtInt = expiresAt.toInt();
                } else {
                  expiresAtInt = int.tryParse(expiresAt.toString()) ?? 0;
                }
                // _log('[SPOTIFY] Token received via WebSocket');
                ref.read(spotifyDirectProvider.notifier).updateToken(
                      accessToken,
                      expiresAtInt,
                    );
                _tokenRequested = false;
                _wsTokenReceived =
                    true; // WS is working, prefer it for future tokens
                // Note: updateToken() already starts direct polling internally
              }
            } else if (type == 'ready') {
              // Connection is truly established - reset retry policy now
              if (!_connectionConfirmed) {
                _connectionConfirmed = true;
                _retryPolicy.reset();
                _log('[WS] Connected successfully');
                state = NowPlayingState(
                  provider: state.provider,
                  payload: state.payload,
                  connected: true,
                  error: null,
                  mode: ref.read(spotifyDirectProvider).mode,
                  wsRetrying: false,
                  wsInCooldown: false,
                );

                // Notify service priority manager that WebSocket is back
                // This allows re-evaluation of cloud services that may have been in cooldown
                ref
                    .read(servicePriorityProvider.notifier)
                    .onWebSocketReconnected();
              }
            } else if (type == 'service_status') {
              // Service health status update from backend
              // Forward to orchestrator for handling recovery logic
              if (onServiceStatus != null) {
                onServiceStatus!(data);
              }
            }
          } catch (e) {
            state = NowPlayingState(
              error: 'Parse error: $e',
              connected: true,
              mode: ref.read(spotifyDirectProvider).mode,
              wsRetrying: false,
              wsInCooldown: false,
            );
          }
        },
        onError: (err) {
          state = NowPlayingState(
            error: 'WebSocket error: $err',
            connected: false,
            provider: state.provider,
            payload: state.payload,
            mode: ref.read(spotifyDirectProvider).mode,
            wsRetrying: true,
            wsInCooldown: false,
          );
          _scheduleRetry();
        },
        onDone: () {
          _log('[WS] onDone: Connection closed by server');
          state = NowPlayingState(
            error: 'Connection closed',
            connected: false,
            provider: state.provider,
            payload: state.payload,
            mode: ref.read(spotifyDirectProvider).mode,
            wsRetrying: true,
            wsInCooldown: false,
          );
          _scheduleRetry();
        },
        cancelOnError: true,
      );
    } finally {
      _connecting = false;
    }
  }

  void _scheduleRetry() {
    _channel = null;
    _connectionConfirmed = false; // Reset to match channel state
    _retryTimer?.cancel();
    final delay = _retryPolicy.nextDelay();
    if (delay == null) {
      _log('[WS] Connection failed after maximum retry time');
      // Update state to show exhausted (not retrying anymore)
      state = NowPlayingState(
        error: state.error,
        connected: false,
        provider: state.provider,
        payload: state.payload,
        mode: ref.read(spotifyDirectProvider).mode,
        wsRetrying: false,
        wsInCooldown: false,
      );
      return; // Exhausted retry window
    }

    // Update state to reflect current retry/cooldown status
    state = NowPlayingState(
      error: state.error,
      connected: false,
      provider: state.provider,
      payload: state.payload,
      mode: ref.read(spotifyDirectProvider).mode,
      wsRetrying: _retryPolicy.isRetrying,
      wsInCooldown: _retryPolicy.inCooldown,
    );

    // _log('[WS] Scheduling retry in ${delay.inMilliseconds}ms');
    _retryTimer = Timer(delay, () async {
      // If channel already exists, skip retry - another connection succeeded
      if (_channel != null) {
        // _log('[WS] Retry skipped - channel already exists');
        return;
      }
      final auth = ref.read(authStateProvider);
      if (!auth.isAuthenticated) return;
      // Only retry if services are (or were) enabled.
      if (!_servicesEnabled(_lastSettings)) return;
      _connect(auth, caller: 'retryTimer');
    });
  }

  void _disconnect({bool scheduleRetry = true}) {
    _retryTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _connectionConfirmed = false;
    _initialConfigSent = false; // Reset so next connect requests token
    _wsTokenReceived = false; // Reset so REST API can be used as fallback
    _lastTokenRequestTime =
        null; // Reset debounce - any pending token request was lost
    _lastSpotifyEnabled = false; // Reset so next enable triggers token request

    // If not scheduling retry (intentional disconnect), reset retry policy
    // so future manual reconnection attempts can proceed
    if (!scheduleRetry) {
      _retryPolicy.reset();
    }

    state = NowPlayingState(
      provider: state.provider,
      payload: state.payload,
      connected: false,
      mode: ref.read(spotifyDirectProvider).mode,
      wsRetrying: _retryPolicy.isRetrying,
      wsInCooldown: _retryPolicy.inCooldown,
    );
    if (scheduleRetry) {
      _scheduleRetry();
    }
  }

  // Public trigger to (re)connect on demand from UI actions.
  void connect() {
    final auth = ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      _refreshAndMaybeConnect(auth);
    }
  }

  /// Force reconnect - disconnect and reconnect immediately
  /// Useful for recovering from sleep/wake scenarios
  void reconnect() {
    // _log('[WS] Force reconnect requested');
    _retryPolicy.reset();
    _disconnect(scheduleRetry: false);
    connect();
  }

  /// Request service health status from the server for specified providers
  /// This is used for probing cloud-based services during recovery
  /// @param providers List of provider names to check (e.g., ['spotify', 'sonos'])
  /// @returns true if request was sent, false if WebSocket not connected
  bool requestServiceStatus(List<String> providers) {
    if (_channel == null || !_connectionConfirmed) {
      _log('[WS] Cannot request service status - not connected');
      return false;
    }

    final payload = jsonEncode({
      'type': 'service_status',
      'providers': providers,
    });

    try {
      _channel?.sink.add(payload);
      _log('[WS] Requested service status for: $providers');
      return true;
    } catch (e) {
      _log('[WS] Error requesting service status: $e');
      return false;
    }
  }

  /// Send config to disable all services on the server
  /// Called when user disables all services
  Future<void> sendDisableAllConfig() async {
    _log('[WS] Sending disable all config');

    final payload = jsonEncode({
      'type': 'config',
      'need_spotify_token': false, // Explicitly cancel token refresh task
      'enabled': {
        'spotify': false,
        'sonos': false,
      },
      'poll': {
        'spotify': null,
        'sonos': null,
      },
    });

    if (_channel == null) {
      _log('[WS] No channel to send disable config - already disconnected');
      return;
    }

    try {
      _channel?.sink.add(payload);
      _log('[WS] Disable all config sent');
    } catch (e) {
      _log('[WS] Error sending disable all config: $e');
    }
  }

  /// Send config based purely on user settings (no active client-side service)
  /// Called when user has services enabled but none are available for client-side use
  /// (e.g., all enabled services are unhealthy). This keeps server-side polling
  /// active for those services so they can recover.
  Future<void> sendConfigForUserSettings() async {
    try {
      final env = ref.read(envConfigProvider);

      // Get poll intervals from settings or defaults
      Map<String, dynamic>? settings = _lastSettings;
      if (settings == null) {
        try {
          final user = await ref.read(userServiceProvider).fetchMe();
          final userId = user['id']?.toString() ?? '';
          if (userId.isNotEmpty) {
            settings = await ref
                .read(settingsServiceProvider)
                .fetchSettingsForUser(userId);
            _lastSettings = settings;
          }
        } catch (_) {
          // Use defaults
        }
      }

      // Get user's enabled settings
      final userSpotifyEnabled = settings?['spotify_enabled'] == true;
      final userSonosEnabled = settings?['sonos_enabled'] == true;

      // If both are disabled, delegate to sendDisableAllConfig
      if (!userSpotifyEnabled && !userSonosEnabled) {
        await sendDisableAllConfig();
        return;
      }

      int? asInt(dynamic v) {
        if (v is int) return v;
        if (v is double) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      int? asIntOrNull(dynamic v) {
        final val = asInt(v);
        return (val == null || val <= 0) ? null : val;
      }

      final spotifyPoll = asInt(settings?['spotify_poll_interval_sec']) ??
          env.spotifyPollIntervalSec;
      final sonosPoll = asIntOrNull(settings?['sonos_poll_interval_sec']) ??
          env.sonosPollIntervalSec;

      // Request token if Spotify is enabled
      final needToken = userSpotifyEnabled;

      _log('[WS] sendConfigForUserSettings: '
          'enabled=(spotify=$userSpotifyEnabled, sonos=$userSonosEnabled), '
          'needToken=$needToken');

      final payload = jsonEncode({
        'type': 'config',
        'need_spotify_token': needToken,
        'enabled': {
          'spotify': userSpotifyEnabled,
          'sonos': userSonosEnabled,
        },
        'poll': {
          'spotify': spotifyPoll,
          'sonos': sonosPoll,
        },
      });

      // If no channel, try to connect first
      if (_channel == null) {
        final auth = ref.read(authStateProvider);
        if (!auth.isAuthenticated || _connecting) return;
        await _connect(auth,
            caller: 'sendConfigForUserSettings', skipSendConfig: true);
        if (_channel != null) {
          _channel?.sink.add(payload);
          _initialConfigSent = true;
        }
        return;
      }

      _initialConfigSent = true;
      _channel?.sink.add(payload);
    } catch (e) {
      _log('[WS] sendConfigForUserSettings error: $e');
    }
  }

  /// Send WebSocket config for a specific service type
  /// This is called by the ServiceOrchestrator when switching services
  /// If [keepSonosEnabled] is true, sonos will be enabled even if not in baseWsConfig
  /// (used when waiting for Sonos to resume after pause)
  /// If [keepSpotifyPollingForRecovery] is true, spotify will be enabled even when
  /// switching to directSpotify (used when cloudSpotify is unhealthy and we want
  /// the server to continue retrying and emit health status when it recovers)
  Future<void> sendConfigForService(ServiceType service,
      {bool keepSonosEnabled = false,
      bool keepSpotifyPollingForRecovery = false}) async {
    try {
      final baseWsConfig = service.webSocketConfig;
      final env = ref.read(envConfigProvider);

      // Update direct polling flag based on the service being activated
      // This is critical for the WebSocket listener to process/ignore incoming data correctly
      _useDirectPolling = service == ServiceType.directSpotify;

      // Get poll intervals from settings or defaults
      Map<String, dynamic>? settings = _lastSettings;
      if (settings == null) {
        try {
          final user = await ref.read(userServiceProvider).fetchMe();
          final userId = user['id']?.toString() ?? '';
          if (userId.isNotEmpty) {
            settings = await ref
                .read(settingsServiceProvider)
                .fetchSettingsForUser(userId);
            _lastSettings = settings;
          }
        } catch (_) {
          // Use defaults
        }
      }

      int? asInt(dynamic v) {
        if (v is int) return v;
        if (v is double) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      // Helper to treat 0 as null (let server decide)
      int? asIntOrNull(dynamic v) {
        final val = asInt(v);
        return (val == null || val <= 0) ? null : val;
      }

      final spotifyPoll = asInt(settings?['spotify_poll_interval_sec']) ??
          env.spotifyPollIntervalSec;
      // Sonos poll: null or 0 = let server decide
      final sonosPoll = asIntOrNull(settings?['sonos_poll_interval_sec']) ??
          env.sonosPollIntervalSec;

      // Get user's enabled settings
      final userSpotifyEnabled = settings?['spotify_enabled'] == true;
      // final userSonosEnabled = settings?['sonos_enabled'] == true;  // Not used - see below

      // Use base WebSocket config for the active service
      // Each service type defines exactly what the server should stream:
      // - directSpotify: spotify=false, sonos=false (client polls Spotify directly)
      // - cloudSpotify: spotify=true, sonos=false (server polls Spotify)
      // - localSonos: spotify=false, sonos=true (server streams Sonos)
      //
      // keepSonosEnabled overrides sonos to true when we need health monitoring
      // during cycling/fallback (e.g., waiting for Sonos to resume)
      //
      // keepSpotifyPollingForRecovery overrides spotify to true when we're falling
      // back from cloudSpotify to directSpotify, so the server continues its retry
      // loop and can emit healthy status when it recovers.
      //
      // NOTE: We intentionally do NOT enable Sonos when directSpotify is active,
      // even if user has Sonos enabled. Receiving Sonos data would cause the
      // orchestrator to switch away from directSpotify prematurely.
      final wsConfig = (
        spotify: baseWsConfig.spotify || keepSpotifyPollingForRecovery,
        sonos: baseWsConfig.sonos || keepSonosEnabled,
      );

      // Token logic: Request token whenever Spotify is enabled in user settings
      // This ensures we have a token ready for direct polling fallback even when
      // another service (like Sonos) is currently active.
      // When Spotify is disabled, explicitly send false to cancel token task on server.
      final needToken = userSpotifyEnabled;

      _log('[WS] sendConfigForService: service=$service, '
          'keepSonosEnabled=$keepSonosEnabled, '
          'keepSpotifyPollingForRecovery=$keepSpotifyPollingForRecovery, '
          'wsConfig=(spotify=${wsConfig.spotify}, sonos=${wsConfig.sonos}), '
          'needToken=$needToken (spotifyEnabled=$userSpotifyEnabled)');

      // Always include need_spotify_token to explicitly tell server what to do
      // true = emit tokens for direct polling, false = cancel token refresh task
      final payload = jsonEncode({
        'type': 'config',
        'need_spotify_token': needToken,
        'enabled': {
          'spotify': wsConfig.spotify,
          'sonos': wsConfig.sonos,
        },
        'poll': {
          'spotify': spotifyPoll,
          'sonos': sonosPoll, // null = let server decide
        },
      });

      // If no channel, try to connect first
      if (_channel == null) {
        final auth = ref.read(authStateProvider);
        if (!auth.isAuthenticated || _connecting) return;
        // Skip sending config in _connect() - we'll send it here after connection
        await _connect(auth,
            caller: 'sendConfigForService', skipSendConfig: true);
        // After connect, send the specific config for this service
        if (_channel != null) {
          _channel?.sink.add(payload);
          _initialConfigSent = true;
        }
        return;
      }

      // Mark initial config as sent
      _initialConfigSent = true;

      // Send the config
      _channel?.sink.add(payload);
    } catch (e) {
      _log('[WS] sendConfigForService error: $e');
    }
  }

  /// Public method to refresh token via REST API
  /// Useful when WebSocket is unavailable
  Future<void> refreshTokenViaRestApi() async {
    await _fetchTokenViaRestApi();
  }

  Future<void> sendConfig({bool forceTokenRequest = false}) async {
    // If there's an active service in the priority system, use sendConfigForService
    // This ensures the new service-based config is used instead of the legacy polling mode logic
    final priority = ref.read(servicePriorityProvider);
    if (priority.currentService != null) {
      _log(
          '[WS] sendConfig delegating to sendConfigForService for ${priority.currentService}');
      await sendConfigForService(priority.currentService!);
      return;
    }

    // Legacy fallback: No active service yet, use old logic
    try {
      Map<String, dynamic>? settings;
      try {
        final user = await ref.read(userServiceProvider).fetchMe();
        final userId = user['id']?.toString() ?? '';
        if (userId.isEmpty) throw Exception('User ID not found');
        settings = await ref
            .read(settingsServiceProvider)
            .fetchSettingsForUser(userId);
        _lastSettings = settings;
        _configRetryTimer?.cancel();
      } catch (_) {
        // On failure, retry soon; use last known settings if we have them, otherwise send a safe disabled payload to unblock server wait.
        _configRetryTimer?.cancel();
        _configRetryTimer = Timer(const Duration(seconds: 2), () {
          // Ignore result; best effort.
          sendConfig();
        });
        settings = _lastSettings ??
            {
              'spotify_enabled': false,
              'sonos_enabled': false,
            };
      }

      final spotifyEnabled = settings['spotify_enabled'] == true;
      final sonosEnabled = settings['sonos_enabled'] == true;
      final hasService = spotifyEnabled || sonosEnabled;

      // Detect if Spotify was just toggled ON
      final spotifyJustEnabled = spotifyEnabled && !_lastSpotifyEnabled;
      _lastSpotifyEnabled = spotifyEnabled; // Update tracking

      // Determine if we should use direct polling
      final directMode = ref.read(spotifyDirectProvider).mode;
      _useDirectPolling =
          spotifyEnabled && directMode == SpotifyPollingMode.direct;
      final env = ref.read(envConfigProvider);
      int? asInt(dynamic v) {
        if (v is int) return v;
        if (v is double) return v.toInt();
        if (v is String) {
          final parsed = int.tryParse(v);
          if (parsed != null) return parsed;
        }
        return null;
      }

      // Helper to treat 0 as null (let server decide)
      int? asIntOrNull(dynamic v) {
        final val = asInt(v);
        return (val == null || val <= 0) ? null : val;
      }

      // Attempt to pick up client-configured poll intervals if present.
      final spotifyPoll = asInt(
            settings['spotify_poll_interval_sec'] ??
                settings['spotify_poll_interval'] ??
                settings['spotify_poll'] ??
                settings['poll_spotify'] ??
                settings['spotify_poll_ms'] ??
                settings['spotify_poll_interval_ms'],
          ) ??
          // If only ms is provided, convert down where possible.
          (() {
            final ms = asInt(settings?['spotify_poll_interval_ms']);
            return ms != null ? (ms / 1000).round() : null;
          })() ??
          env.spotifyPollIntervalSec;

      // Sonos poll: null or 0 = let server decide
      final sonosPoll = asIntOrNull(
            settings['sonos_poll_interval_sec'] ??
                settings['sonos_poll_interval'] ??
                settings['sonos_poll'] ??
                settings['poll_sonos'] ??
                settings['sonos_poll_ms'] ??
                settings['sonos_poll_interval_ms'],
          ) ??
          (() {
            final ms = asIntOrNull(settings?['sonos_poll_interval_ms']);
            return ms;
          })() ??
          env.sonosPollIntervalSec;

      // Request token if Spotify enabled and we don't have a valid token
      // Check if we have a token that's not expired (with 60s buffer)
      final directState = ref.read(spotifyDirectProvider);
      final hasValidToken = directState.accessToken != null &&
          directState.tokenExpiresAt != null &&
          directState.tokenExpiresAt! >
              (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60;

      // Debounce token requests - don't request more than once per 5 seconds
      final now = DateTime.now();
      final tokenRequestDebounced = _lastTokenRequestTime != null &&
          now.difference(_lastTokenRequestTime!).inSeconds < 5;

      // Track if this is the first config after a fresh connection
      final isInitialConfig = !_initialConfigSent;

      // Request token if:
      // 1. This is initial config after connect (server needs to start token refresh scheduler)
      // 2. OR Spotify was just toggled ON (server needs to restart token refresh scheduler)
      // 3. OR forced refresh request (proactive refresh before expiry)
      // 4. OR we don't have a valid token and not debounced
      final needToken = spotifyEnabled &&
          (isInitialConfig ||
              spotifyJustEnabled ||
              forceTokenRequest ||
              (!hasValidToken && !tokenRequestDebounced));

      // Debug logging to understand token request decisions
      _log('[WS] sendConfig decision: spotifyEnabled=$spotifyEnabled, '
          'isInitialConfig=$isInitialConfig, '
          'spotifyJustEnabled=$spotifyJustEnabled, '
          'hasValidToken=$hasValidToken (token=${directState.accessToken != null}, '
          'expiresAt=${directState.tokenExpiresAt}), '
          'debounced=$tokenRequestDebounced (lastReq=$_lastTokenRequestTime), '
          'forceRefresh=$forceTokenRequest => needToken=$needToken');

      // Disable backend services when in direct polling mode
      final backendSpotifyEnabled =
          spotifyEnabled && directMode == SpotifyPollingMode.fallback;
      final backendSonosEnabled = sonosEnabled &&
          (directMode == SpotifyPollingMode.fallback || !spotifyEnabled);

      final payload = jsonEncode({
        'type': 'config',
        if (needToken) 'need_spotify_token': true,
        'enabled': {
          'spotify': backendSpotifyEnabled,
          'sonos': backendSonosEnabled,
        },
        'poll': {
          'spotify': spotifyPoll,
          'sonos': sonosPoll,
        },
      });

      // If we currently have no socket (e.g., after navigation or a tab opened), establish it first.
      if (!hasService) {
        // Nothing to stream; close any existing channel without scheduling retries.
        _disconnect(scheduleRetry: false);
        return;
      }

      // If no channel exists, we need to connect first
      if (_channel == null) {
        final auth = ref.read(authStateProvider);
        if (!auth.isAuthenticated || _connecting) return;
        // Don't bypass retry policy - if we're in a retry cycle, let it handle reconnection
        // But direct polling should still work with existing valid token
        if (_retryPolicy.isRetrying) {
          // If we have a valid token and direct polling isn't running, start it
          final directState = ref.read(spotifyDirectProvider);
          if (spotifyEnabled &&
              directState.accessToken != null &&
              directState.mode == SpotifyPollingMode.idle) {
            ref.read(spotifyDirectProvider.notifier).startDirectPolling();
          }
          return;
        }
        await _connect(auth, caller: 'sendConfig');
        return; // _connect will call sendConfig again once connected
      }

      // Only update debounce timestamp when we actually send the request
      if (needToken) {
        _lastTokenRequestTime = DateTime.now();
      }

      // Mark initial config as sent
      _initialConfigSent = true;

      // Cancel any pending retry timer since we have a valid channel
      _retryTimer?.cancel();

      // Channel exists - send the config (even if not yet "connected" state-wise,
      // the channel is ready after awaiting channel.ready in _connect)
      _channel?.sink.add(payload);

      // Start direct polling if we have a valid token and Spotify is enabled
      if (spotifyEnabled && hasValidToken) {
        final currentMode = ref.read(spotifyDirectProvider).mode;
        if (currentMode == SpotifyPollingMode.idle) {
          ref.read(spotifyDirectProvider.notifier).startDirectPolling();
        }
      }
    } catch (_) {
      // best-effort
    }
  }

  bool _servicesEnabled(Map<String, dynamic>? settings) {
    if (settings == null) return false;
    return settings['spotify_enabled'] == true ||
        settings['sonos_enabled'] == true;
  }

  Future<void> _refreshAndMaybeConnect(AuthState auth) async {
    try {
      final user = await ref.read(userServiceProvider).fetchMe();
      final userId = user['id']?.toString() ?? '';
      if (userId.isEmpty) throw Exception('User ID not found');
      final settings =
          await ref.read(settingsServiceProvider).fetchSettingsForUser(userId);
      _lastSettings = settings;
      _configRetryTimer?.cancel();
      if (_servicesEnabled(settings)) {
        // Only connect if not already connected - don't disrupt existing connection
        if (_channel == null && !_connecting) {
          await _connect(auth, caller: 'refreshAndMaybeConnect');
          // } else {
          //   _log(
          //       '[WS] _refreshAndMaybeConnect skipped - already connected');
        }
      } else {
        _disconnect(scheduleRetry: false);
      }
    } catch (_) {
      // If we can't read settings, wait for sendConfig retry path to decide; do not force connect to respect "no services" requirement.
    }
  }

  void _requestTokenRefresh() {
    if (_tokenRequested) return;
    _tokenRequested = true;
    _log('[SPOTIFY] Requesting token refresh');

    // If WS is connected and has sent tokens before, use WS
    if (_channel != null && _wsTokenReceived) {
      sendConfig(forceTokenRequest: true);
    } else {
      // WS not available, use REST API
      _fetchTokenViaRestApi();
    }
  }

  /// Fetch Spotify token via REST API (fallback when WS is unavailable)
  Future<void> _fetchTokenViaRestApi() async {
    try {
      final user = await ref.read(userServiceProvider).fetchMe();
      final userId = user['id']?.toString() ?? '';
      if (userId.isEmpty) {
        _tokenRequested = false;
        return;
      }

      final dio = ref.read(dioProvider);
      final response = await dio.get<Map<String, dynamic>>(
        '/api/users/$userId/services/spotify/access-token',
      );

      final data = response.data;
      if (data == null) {
        _tokenRequested = false;
        return;
      }

      final accessToken = data['access_token'] as String?;
      final expiresAt = data['expires_at'];

      if (accessToken != null && expiresAt != null) {
        int expiresAtInt;
        if (expiresAt is int) {
          expiresAtInt = expiresAt;
        } else if (expiresAt is double) {
          expiresAtInt = expiresAt.toInt();
        } else {
          expiresAtInt = int.tryParse(expiresAt.toString()) ?? 0;
        }

        // _log('[SPOTIFY] Token fetched via REST API');
        ref.read(spotifyDirectProvider.notifier).updateToken(
              accessToken,
              expiresAtInt,
            );
        // Note: updateToken() already starts direct polling internally
      }
    } on DioException catch (e) {
      _log('[SPOTIFY] REST API token fetch failed: ${e.message}');
    } catch (e) {
      _log('[SPOTIFY] REST API token fetch error: $e');
    } finally {
      _tokenRequested = false;
    }
  }

  /// Try to start direct polling - use cached token or fetch via REST API
  Future<void> _tryStartDirectPollingWithFallback() async {
    final directState = ref.read(spotifyDirectProvider);
    final hasValidToken = directState.accessToken != null &&
        directState.tokenExpiresAt != null &&
        directState.tokenExpiresAt! >
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60;

    if (hasValidToken) {
      // We have a valid cached token, start polling
      if (directState.mode == SpotifyPollingMode.idle) {
        ref.read(spotifyDirectProvider.notifier).startDirectPolling();
      }
    } else {
      // No valid token, try REST API
      _log('[SPOTIFY] No valid token, fetching via REST API...');
      await _fetchTokenViaRestApi();
    }
  }
}

final eventsWsProvider =
    NotifierProvider<EventsWsNotifier, NowPlayingState>(EventsWsNotifier.new);
