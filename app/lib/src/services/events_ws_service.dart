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
  bool _tokenRequested = false;
  DateTime? _lastTokenRequestTime;
  bool _wsTokenReceived =
      false; // Track if WS has sent a token (prefer WS over REST)
  bool _lastSpotifyEnabled = false; // Track previous Spotify enabled state

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

  Future<void> _connect(AuthState auth, {String caller = 'unknown'}) async {
    if (!auth.isAuthenticated) return;

    // CRITICAL: Set _connecting FIRST to prevent race conditions
    // Check and set atomically using a local flag
    if (_connecting) {
      return;
    }
    _connecting = true;

    // If already connected, don't reconnect - just send config
    if (_channel != null && _connectionConfirmed) {
      _connecting = false; // Reset since we're not actually connecting
      await sendConfig();
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
        // debugPrint('[WS] Unable to connect to server, will retry...');
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

      // Send current service enablement to the server.
      await sendConfig();

      _channel?.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            final type = data['type'];
            if (type == 'now_playing') {
              // Only use backend data if not in direct polling mode
              if (!_useDirectPolling) {
                final provider = data['provider'] as String?;
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
                // debugPrint('[SPOTIFY] Token received via WebSocket');
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
                // debugPrint('[WS] Connected successfully');
                state = NowPlayingState(
                  provider: state.provider,
                  payload: state.payload,
                  connected: true,
                  error: null,
                  mode: ref.read(spotifyDirectProvider).mode,
                  wsRetrying: false,
                  wsInCooldown: false,
                );
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
          debugPrint('[WS] onDone: Connection closed by server');
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
      debugPrint('[WS] Connection failed after maximum retry time');
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

    // debugPrint('[WS] Scheduling retry in ${delay.inMilliseconds}ms');
    _retryTimer = Timer(delay, () async {
      // If channel already exists, skip retry - another connection succeeded
      if (_channel != null) {
        // debugPrint('[WS] Retry skipped - channel already exists');
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
    // debugPrint('[WS] Force reconnect requested');
    _retryPolicy.reset();
    _disconnect(scheduleRetry: false);
    connect();
  }

  /// Public method to refresh token via REST API
  /// Useful when WebSocket is unavailable
  Future<void> refreshTokenViaRestApi() async {
    await _fetchTokenViaRestApi();
  }

  Future<void> sendConfig({bool forceTokenRequest = false}) async {
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

      final sonosPoll = asInt(
            settings['sonos_poll_interval_sec'] ??
                settings['sonos_poll_interval'] ??
                settings['sonos_poll'] ??
                settings['poll_sonos'] ??
                settings['sonos_poll_ms'] ??
                settings['sonos_poll_interval_ms'],
          ) ??
          (() {
            final ms = asInt(settings?['sonos_poll_interval_ms']);
            return ms != null ? (ms / 1000).round() : null;
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
      debugPrint('[WS] sendConfig decision: spotifyEnabled=$spotifyEnabled, '
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
          //   debugPrint(
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
    debugPrint('[SPOTIFY] Requesting token refresh');

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

        // debugPrint('[SPOTIFY] Token fetched via REST API');
        ref.read(spotifyDirectProvider.notifier).updateToken(
              accessToken,
              expiresAtInt,
            );
        // Note: updateToken() already starts direct polling internally
      }
    } on DioException catch (e) {
      debugPrint('[SPOTIFY] REST API token fetch failed: ${e.message}');
    } catch (e) {
      debugPrint('[SPOTIFY] REST API token fetch error: $e');
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
      debugPrint('[SPOTIFY] No valid token, fetching via REST API...');
      await _fetchTokenViaRestApi();
    }
  }
}

final eventsWsProvider =
    NotifierProvider<EventsWsNotifier, NowPlayingState>(EventsWsNotifier.new);
