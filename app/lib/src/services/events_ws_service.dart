import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';

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
  int _rapidAttempts = 0;
  DateTime? _windowStart;

  @override
  NowPlayingState build() {
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

  void _connect(AuthState auth) {
    if (!auth.isAuthenticated) return;
    final env = ref.read(envConfigProvider);
    _retryTimer?.cancel();
    _windowStart ??= DateTime.now();
    final uri = Uri.parse('${env.eventsWsUrl}?token=${auth.token}');
    _channel = WebSocketChannel.connect(uri);
    state = const NowPlayingState(connected: true);

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
    final now = DateTime.now();
    _windowStart ??= now;
    final elapsedMs = now.difference(_windowStart!).inMilliseconds;

    const rapidIntervalMs = 2000;
    const rapidMax = 15;
    const cooldownMs = 5 * 60 * 1000;
    const windowMs = 28 * 1000;

    if (elapsedMs > windowMs) {
      // Reset window and attempts after the window passes
      _windowStart = now;
      _rapidAttempts = 0;
    }

    if (_rapidAttempts < rapidMax) {
      _rapidAttempts += 1;
      _retryTimer = Timer(const Duration(milliseconds: rapidIntervalMs), () {
        final auth = ref.read(authStateProvider);
        if (auth.isAuthenticated) {
          _connect(auth);
        }
      });
      return;
    }

    // Back off for a cooldown period after rapid retries are exhausted
    _retryTimer = Timer(const Duration(milliseconds: cooldownMs), () {
      _windowStart = DateTime.now();
      _rapidAttempts = 0;
      final auth = ref.read(authStateProvider);
      if (auth.isAuthenticated) {
        _connect(auth);
      }
    });
  }

  void _disconnect() {
    _retryTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    state = NowPlayingState(provider: state.provider, payload: state.payload, connected: false);
  }

  // Public trigger to (re)connect on demand from UI actions.
  void connect() {
    final auth = ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      _connect(auth);
    }
  }
}

final eventsWsProvider = NotifierProvider.autoDispose<EventsWsNotifier, NowPlayingState>(EventsWsNotifier.new);
