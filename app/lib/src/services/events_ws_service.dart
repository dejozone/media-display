import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/user_service.dart';
import 'package:media_display/src/services/ws_retry_policy.dart';
import 'package:media_display/src/services/ws_ssl_override.dart'
    if (dart.library.io) 'package:media_display/src/services/ws_ssl_override_io.dart';

class NowPlayingState {
  const NowPlayingState(
      {this.provider, this.payload, this.error, this.connected = false});
  final String? provider;
  final Map<String, dynamic>? payload;
  final String? error;
  final bool connected;
}

class EventsWsNotifier extends Notifier<NowPlayingState> {
  WebSocketChannel? _channel;
  Timer? _retryTimer;
  Timer? _configRetryTimer;
  late final WsRetryPolicy _retryPolicy;
  bool _connecting = false;
  Map<String, dynamic>? _lastSettings;

  @override
  NowPlayingState build() {
    final env = ref.read(envConfigProvider);
    _retryPolicy = WsRetryPolicy(
      interval: Duration(milliseconds: env.wsRetryIntervalMs),
      activeWindow: Duration(seconds: env.wsRetryActiveSeconds),
      cooldown: Duration(seconds: env.wsRetryCooldownSeconds),
      maxTotal: Duration(seconds: env.wsRetryMaxTotalSeconds),
    );

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
        _disconnect();
      }
    });

    final auth = ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      _refreshAndMaybeConnect(auth);
    }

    return const NowPlayingState();
  }

  Future<void> _connect(AuthState auth) async {
    if (!auth.isAuthenticated) return;
    if (_connecting) return;
    _connecting = true;

    try {
      // Ensure we don't stack multiple channels; close any existing one first.
      _disconnect(scheduleRetry: false);
      final env = ref.read(envConfigProvider);
      _retryTimer?.cancel();
      final uri = Uri.parse('${env.eventsWsUrl}?token=${auth.token}');
      try {
        await withInsecureWs(() async {
          _channel = WebSocketChannel.connect(uri);
        }, allowInsecure: !env.eventsWsSslVerify);
      } catch (e) {
        state = NowPlayingState(
            error: 'WebSocket connect failed: $e',
            connected: false,
            provider: state.provider,
            payload: state.payload);
        _channel = null;
        _scheduleRetry();
        return;
      }

      _retryPolicy.reset();
      state = NowPlayingState(
        provider: state.provider,
        payload: state.payload,
        connected: true,
        error: null,
      );

      // Send current service enablement to the server.
      await sendConfig();

      _channel?.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            final type = data['type'];
            if (type == 'now_playing') {
              final provider = data['provider'] as String?;
              final payload = (data['data'] as Map?)?.cast<String, dynamic>();
              state = NowPlayingState(
                  provider: provider, payload: payload, connected: true);
            } else if (type == 'ready') {
              // ready message ignored for now
            }
          } catch (e) {
            state = NowPlayingState(error: 'Parse error: $e', connected: true);
          }
        },
        onError: (err) {
          state = NowPlayingState(
              error: 'WebSocket error: $err',
              connected: false,
              provider: state.provider,
              payload: state.payload);
          _scheduleRetry();
        },
        onDone: () {
          state = NowPlayingState(
              error: 'Connection closed',
              connected: false,
              provider: state.provider,
              payload: state.payload);
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
    _retryTimer?.cancel();
    final delay = _retryPolicy.nextDelay();
    if (delay == null) {
      return; // Exhausted retry window
    }
    _retryTimer = Timer(delay, () async {
      final auth = ref.read(authStateProvider);
      if (!auth.isAuthenticated) return;
      // Only retry if services are (or were) enabled.
      if (!_servicesEnabled(_lastSettings)) return;
      _connect(auth);
    });
  }

  void _disconnect({bool scheduleRetry = true}) {
    _retryTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    state = NowPlayingState(
        provider: state.provider, payload: state.payload, connected: false);
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

  Future<void> sendConfig() async {
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
      final hasService = _servicesEnabled(settings);
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
            final ms = asInt(settings?['spotify_poll_interval_ms'] ?? 0);
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

      final payload = jsonEncode({
        'type': 'config',
        'enabled': {
          'spotify': settings['spotify_enabled'] == true,
          'sonos': settings['sonos_enabled'] == true,
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

      if (_channel == null || state.connected == false) {
        final auth = ref.read(authStateProvider);
        if (!auth.isAuthenticated || _connecting) return;
        await _connect(auth);
        return; // _connect will call sendConfig again once connected
      }
      _channel?.sink.add(payload);
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
        await _connect(auth);
      } else {
        _disconnect(scheduleRetry: false);
      }
    } catch (_) {
      // If we can't read settings, wait for sendConfig retry path to decide; do not force connect to respect "no services" requirement.
    }
  }
}

final eventsWsProvider =
    NotifierProvider<EventsWsNotifier, NowPlayingState>(EventsWsNotifier.new);
