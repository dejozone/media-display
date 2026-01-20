import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/ws_retry_policy.dart';
import 'package:media_display/src/services/ws_ssl_override.dart'
  if (dart.library.io) 'package:media_display/src/services/ws_ssl_override_io.dart';

class NowPlayingState {
  const NowPlayingState({this.provider, this.payload, this.error, this.connected = false});
  final String? provider;
  final Map<String, dynamic>? payload;
  final String? error;
  final bool connected;
}

class EventsWsNotifier extends Notifier<NowPlayingState> {
  WebSocketChannel? _channel;
  Timer? _retryTimer;
  late final WsRetryPolicy _retryPolicy;

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
      _channel?.sink.close();
    });

    // React to auth changes and connect/disconnect accordingly.
    ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (next.isAuthenticated && (prev == null || !prev.isAuthenticated)) {
        _connect(next);
      }
      if (!next.isAuthenticated) {
        _disconnect();
      }
    });

    final auth = ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      _connect(auth);
    }

    return const NowPlayingState();
  }

  Future<void> _connect(AuthState auth) async {
    if (!auth.isAuthenticated) return;
    final shouldConnect = await _shouldConnectToServices();
    if (!shouldConnect) {
      _disconnect(scheduleRetry: false);
      return;
    }
    final env = ref.read(envConfigProvider);
    _retryTimer?.cancel();
    final uri = Uri.parse('${env.eventsWsUrl}?token=${auth.token}');
    await withInsecureWs(() async {
      _channel = WebSocketChannel.connect(uri);
    }, allowInsecure: !env.eventsWsSslVerify);
    _retryPolicy.reset();
    state = NowPlayingState(
      provider: state.provider,
      payload: state.payload,
      connected: true,
      error: null,
    );

    _channel?.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          final type = data['type'];
          if (type == 'now_playing') {
            final provider = data['provider'] as String?;
            final payload = (data['data'] as Map?)?.cast<String, dynamic>();
            state = NowPlayingState(provider: provider, payload: payload, connected: true);
          } else if (type == 'ready') {
            // ready message ignored for now
          }
        } catch (e) {
          state = NowPlayingState(error: 'Parse error: $e', connected: true);
        }
      },
      onError: (err) {
        state = NowPlayingState(error: 'WebSocket error: $err', connected: false, provider: state.provider, payload: state.payload);
        _scheduleRetry();
      },
      onDone: () {
        state = NowPlayingState(error: 'Connection closed', connected: false, provider: state.provider, payload: state.payload);
        _scheduleRetry();
      },
      cancelOnError: true,
    );
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
      final shouldConnect = await _shouldConnectToServices();
      if (shouldConnect) {
        _connect(auth);
      }
    });
  }

  void _disconnect({bool scheduleRetry = true}) {
    _retryTimer?.cancel();
      _channel?.sink.close();
    _channel = null;
    state = NowPlayingState(provider: state.provider, payload: state.payload, connected: false);
    if (scheduleRetry) {
      _scheduleRetry();
    }
  }

  // Public trigger to (re)connect on demand from UI actions.
  void connect() {
    final auth = ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      _connect(auth);
    }
  }

  Future<bool> _shouldConnectToServices() async {
    try {
      final settings = await ref.read(settingsServiceProvider).fetchSettings();
      final spotify = settings['spotify_enabled'] == true;
      final sonos = settings['sonos_enabled'] == true;
      return spotify || sonos;
    } catch (_) {
      return true; // fall back to connecting if settings cannot be fetched
    }
  }
}

final eventsWsProvider = NotifierProvider.autoDispose<EventsWsNotifier, NowPlayingState>(EventsWsNotifier.new);
