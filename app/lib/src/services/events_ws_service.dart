import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
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
import 'package:media_display/src/utils/logging.dart';

final _logger = appLogger('EventsWs');

void _log(String message, {Level level = Level.INFO}) {
  _logger.log(level, message);
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
  bool _hasConnectedOnce =
      false; // Track first successful WS ready in this auth session
  bool _initialConfigSent = false; // Track if initial config sent after connect
  Map<String, dynamic>? _lastSettings;
  bool _useDirectPolling = false;

  /// Update the cached settings. Call this before sendConfig when settings change.
  void updateCachedSettings(Map<String, dynamic> settings) {
    _lastSettings = settings;
  }

  /// Clean shutdown used on logout: no retries, clear cached settings/state,
  /// and prevent fallback direct polling from being triggered.
  void disconnectOnLogout() {
    _log('Disconnecting due to logout');
    _useDirectPolling = false;
    _lastSettings = null;
    _lastConfigSent = null;
    _lastConfigJson = null;
    _lastConfigSentAt = null;
    _tokenRequested = false;
    _lastTokenRequestTime = null;
    _wsTokenReceived = false;
    _lastEnabledSent.clear();
    _configRetryTimer?.cancel();
    _retryTimer?.cancel();
    _disconnect(scheduleRetry: false, resetFirstConnectFlag: true);
  }

  bool _tokenRequested = false;
  DateTime? _lastTokenRequestTime;
  bool _wsTokenReceived =
      false; // Track if WS has sent a token (prefer WS over REST)
  bool _lastSpotifyEnabled = false; // Track previous Spotify enabled state
  // Track last enabled states sent during the current WebSocket connection
  // to avoid re-sending redundant enabled=true toggles. Reset on disconnect.
  final Map<String, bool> _lastEnabledSent = {};
  Map<String, dynamic>? _lastConfigSent; // Last config payload sent to server
  String? _lastConfigJson; // Serialized payload for duplicate suppression
  DateTime? _lastConfigSentAt;

  /// Callback for service status updates (set by orchestrator)
  ServiceStatusCallback? onServiceStatus;

  @override
  NowPlayingState build() {
    final env = ref.read(envConfigProvider);
    _retryPolicy = WsRetryPolicy(
      interval: Duration(milliseconds: env.wsRetryIntervalMs),
      activeWindow: Duration(seconds: env.wsRetryActiveSec),
      cooldown: Duration(seconds: env.wsRetryCooldownSec),
      retryWindow: Duration(seconds: env.wsRetryWindowSec),
    );

    final retryWindowLabel =
        env.wsRetryWindowSec <= 0 ? 'forever' : '${env.wsRetryWindowSec}s';
    _log('Retry policy initialized: interval=${env.wsRetryIntervalMs}ms, '
        'active=${env.wsRetryActiveSec}s, cooldown=${env.wsRetryCooldownSec}s, '
        'window=$retryWindowLabel');

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
        _disconnect(resetFirstConnectFlag: true);
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

    // Respect cooldown: if a retry is already scheduled while we're in cooldown,
    // do not cancel it or attempt a new connection earlier than planned.
    if (_retryTimer?.isActive == true && _retryPolicy.inCooldown) {
      return;
    }

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
      // Do NOT reset retry policy here; we want retries to honor the same
      // policy across attempts. Retry state resets only on successful connect
      // (ready) or explicit manual reset.
      _disconnect(
        scheduleRetry: false,
        resetRetryPolicy: false,
        cancelRetryTimer: false,
      );
      final env = ref.read(envConfigProvider);
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
        // _log('Unable to connect to server, will retry...');
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

      // On reconnects, defer sending config until after the socket is fully ready
      // and the priority manager has re-run initial activation. This prevents
      // sending a stale config for the previous (fallback) service before the
      // reconnect cold-start selects the highest-priority service.
      final deferConfigForReconnect = _hasConnectedOnce;

      // Send current service enablement to the server (unless skipped by caller).
      // If a service is already selected, let the orchestrator-driven config
      // send (or the caller) handle it to avoid duplicate configs on first login.
      if (!skipSendConfig && !deferConfigForReconnect) {
        final currentService = ref.read(servicePriorityProvider).currentService;
        if (currentService == null) {
          await sendConfig();
        }
      } else if (deferConfigForReconnect) {
        // _log(
        //     'Skipping initial config on reconnect; will send after priority reset');
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
                _log('Token received via server push');
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
                _log('Connected successfully');
                state = NowPlayingState(
                  provider: state.provider,
                  payload: state.payload,
                  connected: true,
                  error: null,
                  mode: ref.read(spotifyDirectProvider).mode,
                  wsRetrying: false,
                  wsInCooldown: false,
                );

                // Only treat as reconnect after we've had a prior successful ready
                if (_hasConnectedOnce) {
                  ref
                      .read(servicePriorityProvider.notifier)
                      .onWebSocketReconnected();
                  // After priority resets and re-activates, send config for the
                  // newly selected highest-priority service.
                  Future.microtask(() => sendConfig());
                } else {
                  _hasConnectedOnce = true;
                  // First connection: send config now to start services.
                  Future.microtask(() => sendConfig());
                }
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
          _log('onDone: Connection closed by server');
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
    // If a retry is already scheduled (including cooldown), do not override it.
    if (_retryTimer?.isActive == true) {
      return;
    }

    _channel = null;
    _connectionConfirmed = false; // Reset to match channel state
    _retryTimer?.cancel();
    final delay = _retryPolicy.nextDelay();
    if (delay == null) {
      _log('Connection failed after maximum retry time');
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

    // _log('Scheduling retry in ${delay.inMilliseconds}ms '
    //     '(cooldown=${_retryPolicy.inCooldown}, retryCount=${_retryPolicy.retryCount})');
    _retryTimer = Timer(delay, () async {
      // If channel already exists, skip retry - another connection succeeded
      if (_channel != null) {
        // _log('Retry skipped - channel already exists');
        return;
      }
      final auth = ref.read(authStateProvider);
      if (!auth.isAuthenticated) return;
      // Only retry if services are (or were) enabled.
      if (!_servicesEnabled(_lastSettings)) return;
      _connect(auth, caller: 'retryTimer');
    });
  }

  void _disconnect({
    bool scheduleRetry = true,
    bool resetFirstConnectFlag = false,
    bool resetRetryPolicy = true,
    bool cancelRetryTimer = true,
  }) {
    if (cancelRetryTimer) {
      _retryTimer?.cancel();
    }
    _channel?.sink.close();
    _channel = null;
    _connectionConfirmed = false;
    if (resetFirstConnectFlag) {
      _hasConnectedOnce = false;
    }
    _initialConfigSent = false; // Reset so next connect requests token
    _wsTokenReceived = false; // Reset so REST API can be used as fallback
    _lastTokenRequestTime =
        null; // Reset debounce - any pending token request was lost
    _lastSpotifyEnabled = false; // Reset so next enable triggers token request
    _lastEnabledSent.clear(); // Reset per-connection enable tracking
    _lastConfigJson = null;

    // If not scheduling retry (intentional disconnect), optionally reset retry
    // policy so future manual reconnection attempts can proceed.
    if (!scheduleRetry && resetRetryPolicy) {
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
    // _log('Force reconnect requested');
    _retryPolicy.reset();
    _disconnect(scheduleRetry: false, resetRetryPolicy: false);
    connect();
  }

  /// Request service health status from the server for specified providers
  /// This is used for probing cloud-based services during recovery
  /// @param providers List of provider names to check (e.g., ['spotify', 'sonos'])
  /// @returns true if request was sent, false if WebSocket not connected
  bool requestServiceStatus(List<String> providers) {
    if (_channel == null || !_connectionConfirmed) {
      _log('Cannot request service status - not connected');
      return false;
    }

    final payload = jsonEncode({
      'type': 'service_status',
      'providers': providers,
    });

    try {
      _channel?.sink.add(payload);
      _log('Requested service status for: $providers');
      return true;
    } catch (e) {
      _log('Error requesting service status: $e');
      return false;
    }
  }

  /// Send a minimal config payload to disable Spotify only.
  /// This is used when the user removes Spotify from the account settings page
  /// and we need to stop server-side polling immediately without touching Sonos
  /// settings.
  Future<void> sendSpotifyDisableOnly() async {
    if (!ref.read(authStateProvider).isAuthenticated) {
      _log('Cannot send Spotify disable config - not authenticated');
      return;
    }
    if (_channel == null) {
      _log('Cannot send Spotify disable config - no channel');
      return;
    }

    final payload = {
      'type': 'config',
      'enabled': {
        'spotify': false,
      },
    };

    await _sendConfigPayload(payload, logLabel: 'minimal Spotify disable');
  }

  /// Send config to disable all services on the server
  /// Called when user disables all services
  Future<void> sendDisableAllConfig() async {
    if (!ref.read(authStateProvider).isAuthenticated) {
      _log('sendDisableAllConfig skipped - not authenticated');
      return;
    }

    final payload = {
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
    };

    await _sendConfigPayload(payload, logLabel: 'disable all');
  }

  /// Send config based purely on user settings (no active client-side service)
  /// Called when user has services enabled but none are available for client-side use
  /// (e.g., all enabled services are unhealthy). This keeps server-side polling
  /// active for those services so they can recover.
  Future<void> sendConfigForUserSettings() async {
    // Skip sending config when not authenticated (logout path)
    if (!ref.read(authStateProvider).isAuthenticated) {
      _log('sendConfigForUserSettings skipped - not authenticated');
      return;
    }

    try {
      // If a direct Spotify service is currently active, defer to the
      // service-specific config to avoid re-enabling backend Spotify polling
      // while the client is handling playback directly.
      final priority = ref.read(servicePriorityProvider);
      if (priority.currentService == ServiceType.directSpotify) {
        await sendConfigForService(ServiceType.directSpotify);
        return;
      }

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

      // If both are disabled, delegate to sendDisableAllConfig unless we just
      // sent an equivalent disable payload very recently (to avoid duplicates
      // when orchestrator falls back after a targeted disable message).
      if (!userSpotifyEnabled && !userSonosEnabled) {
        final recentlySentDisable = _isDisableConfig(_lastConfigSent) &&
            _lastConfigSentAt != null &&
            DateTime.now().difference(_lastConfigSentAt!) <=
                const Duration(seconds: 2);
        if (!recentlySentDisable) {
          await sendDisableAllConfig();
        } else {
          _log('Suppressing duplicate disable-all config');
        }
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
          env.cloudSpotifyPollIntervalSec;
      final sonosPoll = asIntOrNull(settings?['sonos_poll_interval_sec']) ??
          env.sonosPollIntervalSec;

      // Request token if Spotify is enabled
      final needToken = userSpotifyEnabled;

      _log('sendConfigForUserSettings: '
          'enabled=(spotify=$userSpotifyEnabled, sonos=$userSonosEnabled), '
          'needToken=$needToken');

      final payload = {
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
        if (userSpotifyEnabled)
          'fallback': {
            'spotify': false,
          },
      };

      // If no channel, try to connect first
      if (_channel == null) {
        final auth = ref.read(authStateProvider);
        if (!auth.isAuthenticated || _connecting) return;
        await _connect(auth,
            caller: 'sendConfigForUserSettings', skipSendConfig: true);
        if (_channel != null) {
          await _sendConfigPayload(payload,
              logLabel: 'user settings (post-connect)');
          _initialConfigSent = true;
        }
        return;
      }

      _initialConfigSent = true;
      await _sendConfigPayload(payload, logLabel: 'user settings');
    } catch (e) {
      _log('sendConfigForUserSettings error: $e');
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
      if (!ref.read(authStateProvider).isAuthenticated) {
        _log('sendConfigForService skipped - not authenticated');
        return;
      }

      final baseWsConfig = service.webSocketConfig;
      final priority = ref.read(servicePriorityProvider);
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
          env.cloudSpotifyPollIntervalSec;
      // Sonos poll: null or 0 = let server decide
      final sonosPoll = asIntOrNull(settings?['sonos_poll_interval_sec']) ??
          env.sonosPollIntervalSec;

      // Get user's enabled settings
      final userSpotifyEnabled = settings?['spotify_enabled'] == true;
      final userSonosEnabled = settings?['sonos_enabled'] == true;

      // Use base WebSocket config for the active service
      // Each service type defines exactly what the server should stream:
      // - directSpotify: spotify=false, sonos=false (client polls Spotify directly;
      //   we still keep server Spotify polling if user enabled to allow recovery)
      // - cloudSpotify: spotify=true, sonos=false (server polls Spotify)
      // - localSonos: spotify=false, sonos=true (server streams Sonos)
      //
      // keepSonosEnabled overrides sonos to true when we need health monitoring
      // during cycling/fallback (e.g., waiting for Sonos to resume)
      //
      // keepSpotifyPollingForRecovery overrides spotify to true when we're falling
      // back from cloudSpotify to directSpotify, so the server continues its retry
      // loop and can emit healthy status when it recovers (still gated by user setting).
      //
      // Only keep an extra service enabled when that service is marked as
      // awaiting recovery; otherwise enforce a single enabled service to avoid
      // sending configs with both spotify and sonos true.
      final allowKeepSpotify = keepSpotifyPollingForRecovery &&
          priority.awaitingRecovery.contains(ServiceType.cloudSpotify);
      final allowKeepSonos = keepSonosEnabled &&
          priority.awaitingRecovery.contains(ServiceType.localSonos);
      //
      // NOTE: We intentionally do NOT enable Sonos when directSpotify is active,
      // even if user has Sonos enabled. Receiving Sonos data would cause the
      // orchestrator to switch away from directSpotify prematurely.
      final wsConfig = (
        spotify: baseWsConfig.spotify || allowKeepSpotify,
        sonos: baseWsConfig.sonos || allowKeepSonos,
      );

      // Token logic: Request token whenever Spotify is enabled in user settings
      // This ensures we have a token ready for direct polling fallback even when
      // another service (like Sonos) is currently active.
      // When Spotify is disabled, explicitly send false to cancel token task on server.
      final needToken = userSpotifyEnabled;

      // Build minimal enabled/poll maps so unspecified services remain untouched
      // on the server. Only include the service being switched (and any explicitly
      // kept-for-recovery flags).
      final enabled = <String, bool>{};
      final poll = <String, int?>{};

      void setSpotify(bool value) {
        enabled['spotify'] = value;
        poll['spotify'] = spotifyPoll;
      }

      void setSonos(bool value) {
        enabled['sonos'] = value;
        poll['sonos'] = sonosPoll;
      }

      // Helper to decide whether to explicitly set spotify enabled/disabled.
      // We avoid sending "disable" when switching away from cloud Spotify so the
      // server can keep retrying; we only send true for recovery, or false if the
      // user disabled Spotify in settings.
      bool shouldExplicitlyEnableSpotifyForRecovery() =>
          allowKeepSpotify && userSpotifyEnabled;
      bool shouldExplicitlyDisableSpotify() => !userSpotifyEnabled;

      if (service == ServiceType.directSpotify) {
        // Do not disable server Spotify polling; let it keep retrying.
        // Only send enable if explicitly keeping for recovery, and send disable
        // if the user turned Spotify off in settings.
        if (shouldExplicitlyEnableSpotifyForRecovery()) {
          setSpotify(true);
        } else if (shouldExplicitlyDisableSpotify()) {
          setSpotify(false);
        }

        // Keep Sonos enabled only when explicitly requested and user has Sonos enabled.
        if (wsConfig.sonos && userSonosEnabled) setSonos(true);
        if (!userSonosEnabled) setSonos(false);
      } else if (service == ServiceType.cloudSpotify) {
        // Enable backend Spotify polling; Sonos only if explicitly kept and user enabled.
        setSpotify(userSpotifyEnabled);
        if (wsConfig.sonos && userSonosEnabled) {
          setSonos(true);
        } else if (!userSonosEnabled) {
          setSonos(false);
        }
      } else if (service == ServiceType.localSonos) {
        // Enable Sonos streaming. Disable Spotify on the server unless we are
        // explicitly keeping it for recovery. This ensures lower-priority
        // cloud_spotify stops when Sonos takes over.
        // When not keeping Spotify for recovery, also drop spotify poll entry
        // to avoid emitting any temporary spotify=true configs.
        setSonos(userSonosEnabled);
        if (shouldExplicitlyEnableSpotifyForRecovery()) {
          setSpotify(true);
        } else {
          setSpotify(false);
          poll.remove('spotify');
        }
      }

      final payload = {
        'type': 'config',
        'need_spotify_token': needToken,
        'enabled': enabled,
        'poll': poll,
        if (enabled['spotify'] == true)
          'fallback': {
            'spotify': false,
          },
      };

      // If no channel, try to connect first
      if (_channel == null) {
        final auth = ref.read(authStateProvider);
        if (!auth.isAuthenticated || _connecting) return;
        // Skip sending config in _connect() - we'll send it here after connection
        await _connect(auth,
            caller: 'sendConfigForService', skipSendConfig: true);
        // After connect, send the specific config for this service
        if (_channel != null) {
          await _sendConfigPayload(payload,
              logLabel: 'service config (post-connect)');
          _initialConfigSent = true;
        }
        return;
      }

      // Mark initial config as sent
      _initialConfigSent = true;

      // Send the config
      await _sendConfigPayload(payload, logLabel: 'service config');
    } catch (e) {
      _log('sendConfigForService error: $e');
    }
  }

  /// Trigger Sonos re-discovery by sending config with enabled.sonos=true
  /// This is called when Spotify detects playback on a "Speaker" device,
  /// which likely means music is playing on Sonos devices but the server
  /// may not have the correct coordinator. Re-sending the config triggers
  /// Sonos device discovery to find the right coordinator.
  Future<void> triggerSonosDiscovery() async {
    try {
      // If Sonos is waiting for recovery and we are not on Sonos, avoid
      // toggling configs that would disable the active Spotify service.
      final priority = ref.read(servicePriorityProvider);
      final current = priority.currentService;
      final sonosAwaiting =
          priority.awaitingRecovery.contains(ServiceType.localSonos);

      if (sonosAwaiting && current != ServiceType.localSonos) {
        _log('triggerSonosDiscovery: skipping because Sonos awaiting recovery while on $current');
        return;
      }

      // Keep Spotify enabled when the active service is not Sonos so we don't
      // drop the current fallback (e.g., cloudSpotify) during discovery.
      final keepSpotify = current != ServiceType.localSonos;

        _log('triggerSonosDiscovery: delegating to sendConfigForService(localSonos) (keepSpotify=$keepSpotify)');
      await sendConfigForService(
        ServiceType.localSonos,
        keepSpotifyPollingForRecovery: keepSpotify,
      );
    } catch (e) {
      _log('triggerSonosDiscovery error: $e');
    }
  }

  /// Public method to refresh token via REST API
  /// Useful when WebSocket is unavailable
  Future<void> refreshTokenViaRestApi() async {
    await _fetchTokenViaRestApi();
  }

  Future<void> sendConfig({bool forceTokenRequest = false}) async {
    // Skip config when not authenticated (logout path)
    if (!ref.read(authStateProvider).isAuthenticated) {
      _log('sendConfig skipped - not authenticated');
      return;
    }

    // If there's an active service in the priority system, use sendConfigForService
    // This ensures the new service-based config is used instead of the legacy polling mode logic
    final priority = ref.read(servicePriorityProvider);
    if (priority.currentService != null) {
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
          env.cloudSpotifyPollIntervalSec;

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
      _log('sendConfig decision: spotifyEnabled=$spotifyEnabled, '
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

      final payload = {
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
        if (backendSpotifyEnabled)
          'fallback': {
            'spotify': false,
          },
      };

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
      await _sendConfigPayload(payload, logLabel: 'legacy config');

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

  /// Send a config payload if it's not identical to the last one sent.
  Future<void> _sendConfigPayload(Map<String, dynamic> payload,
      {required String logLabel}) async {
    try {
      // Drop redundant enabled=true toggles while the WebSocket stays alive.
      // Server keeps services enabled until explicitly disabled, so re-sending
      // true is unnecessary and causes noisy config churn.
      final mutable = Map<String, dynamic>.from(payload);
      final enabled = (mutable['enabled'] as Map?)?.cast<String, bool>();
      if (enabled != null) {
        final filtered = <String, bool>{};
        enabled.forEach((key, value) {
          final prev = _lastEnabledSent[key];
          // Only skip when re-sending true that we've already sent in this connection.
          if (value == true && prev == true) return;
          filtered[key] = value;
        });

        if (filtered.isEmpty) {
          mutable.remove('enabled');
        } else {
          mutable['enabled'] = filtered;
        }
      }

      final payloadJson = jsonEncode(mutable);

      if (payloadJson == _lastConfigJson) {
        // Drop exact duplicate configs to prevent churn (e.g., repeated Sonos disable)
        return;
      }

      if (_channel == null) {
        _log('No channel to send $logLabel config');
        return;
      }

      _channel?.sink.add(payloadJson);
      _lastConfigSent = mutable;
      _lastConfigJson = payloadJson;
      _lastConfigSentAt = DateTime.now();
      // Update enabled tracking only with what we actually sent
      final sentEnabled = (mutable['enabled'] as Map?)?.cast<String, bool>();
      if (sentEnabled != null) {
        _lastEnabledSent.addAll(sentEnabled);
      }
      _log('Config sent: $logLabel, raw=$payloadJson');
    } catch (e) {
      _log('Error sending $logLabel config: $e');
    }
  }

  bool _isDisableConfig(Map<String, dynamic>? payload) {
    if (payload == null) return false;
    if (payload['type'] != 'config') return false;
    final enabled = payload['enabled'];
    if (enabled is! Map) return false;
    final spotifyDisabled = enabled['spotify'] == false;
    final sonosDisabled =
        enabled['sonos'] == false || !enabled.containsKey('sonos');
    return spotifyDisabled && sonosDisabled;
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
          //   _log('_refreshAndMaybeConnect skipped - already connected');
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
    _log('Requesting token refresh');

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

        _log('Token fetched via REST API');
        ref.read(spotifyDirectProvider.notifier).updateToken(
              accessToken,
              expiresAtInt,
            );
        // Note: updateToken() already starts direct polling internally
      }
    } on DioException catch (e) {
      _log('REST API token fetch failed: ${e.message}');
    } catch (e) {
      _log('REST API token fetch error: $e');
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
      _log('No valid token, fetching via REST API...');
      await _fetchTokenViaRestApi();
    }
  }
}

final eventsWsProvider =
    NotifierProvider<EventsWsNotifier, NowPlayingState>(EventsWsNotifier.new);
