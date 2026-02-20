import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:media_display/src/services/native_sonos_bridge.dart';
import 'package:media_display/src/utils/logging.dart';

final _logger = appLogger('NativeSonos');

void _log(String message, {Level level = Level.INFO}) {
  _logger.log(level, message);
}

class NativeSonosState {
  const NativeSonosState({
    this.payload,
    this.error,
    this.connected = false,
    this.isRunning = false,
  });

  final Map<String, dynamic>? payload;
  final String? error;
  final bool connected;
  final bool isRunning;

  NativeSonosState copyWith({
    Map<String, dynamic>? payload,
    String? error,
    bool? connected,
    bool? isRunning,
    bool clearPayload = false,
    bool clearError = false,
  }) {
    return NativeSonosState(
      payload: clearPayload ? null : (payload ?? this.payload),
      error: clearError ? null : (error ?? this.error),
      connected: connected ?? this.connected,
      isRunning: isRunning ?? this.isRunning,
    );
  }
}

class NativeSonosNotifier extends Notifier<NativeSonosState> {
  NativeSonosBridge? _bridge;
  StreamSubscription<NativeSonosMessage>? _subscription;

  Timer? _healthCheckTimer;
  String? _healthCheckHost;
  int _healthCheckIntervalSec = 0;
  int _healthCheckFailures = 0;
  int _healthCheckRetryMax = 0;
  int _healthCheckTimeoutSec = 5;

  bool _isCoordinatorPayload(Map<String, dynamic> payload) {
    // Expect coordinator flag only under data
    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      final device = data['device'];
      if (device is Map<String, dynamic>) {
        return device['coordinator'] == true || device['isCoordinator'] == true;
      }
    }
    return false;
  }

  void _logPayloadSummary(Map<String, dynamic> payload) {
    final data = payload['data'];
    final device = data is Map<String, dynamic> ? data['device'] : null;
    final deviceName = device is Map<String, dynamic>
        ? (device['name'] ?? device['displayName'])
        : null;
    final isCoordinator = device is Map<String, dynamic>
        ? (device['coordinator'] == true || device['isCoordinator'] == true)
        : null;

    final keys = payload.keys.join(',');
    _log(
        'Payload summary: keys=[$keys], device=$deviceName (isCoordinator=$isCoordinator)');
  }

  String? _coordinatorName(Map<String, dynamic> payload) {
    // Try common fields for identifying the coordinator device name
    final data = payload['data'];
    final device = data is Map<String, dynamic> ? data['device'] : null;
    if (device is Map<String, dynamic>) {
      final name = device['name'] ?? device['displayName'];
      if (name is String && name.isNotEmpty) return name;
    }
    return null;
  }

  String? _coordinatorHost(Map<String, dynamic> payload) {
    final data = payload['data'];
    final device = data is Map<String, dynamic> ? data['device'] : null;
    if (device is Map<String, dynamic>) {
      final ip = device['ip'];
      if (ip is String && ip.isNotEmpty) return ip;
    }
    return null;
  }

  @override
  NativeSonosState build() {
    ref.onDispose(() async {
      await stop();
    });
    return const NativeSonosState();
  }

  Future<void> start({
    int? pollIntervalSec,
    int? healthCheckSec,
    int? healthCheckRetry,
    int? healthCheckTimeoutSec,
    String? coordinatorDiscoveryMethod,
  }) async {
    // If already running and connected, avoid tearing down and re-subscribing.
    if (state.isRunning && state.connected) {
      _log('Already running and connected; skipping restart');
      return;
    }

    // Only tear down when we were already running; initial start should not
    // emit a transient stop event that triggers fallback timers.
    if (state.isRunning) {
      await stop();
    }

    final bridge = _bridge ??= createNativeSonosBridge();
    _log(
        'Bridge created (supported=${bridge.isSupported}, type=${bridge.runtimeType})',
        level: Level.FINE);
    if (!bridge.isSupported) {
      _log(
          'Bridge not available on this platform; falling back to local Sonos if enabled',
          level: Level.WARNING);
      state = state.copyWith(
        error: 'Bridge not available on this platform',
        connected: false,
        isRunning: false,
      );
      return;
    }

    _log(
        'Starting native Sonos bridge (pollIntervalSec=$pollIntervalSec, healthCheckSec=$healthCheckSec, healthCheckRetry=$healthCheckRetry)');

    // Mark running immediately to avoid transient "not connected" fallbacks
    // while the bridge initializes.
    state = state.copyWith(isRunning: true, connected: false, clearError: true);

    _healthCheckIntervalSec = healthCheckSec ?? 0;
    _healthCheckRetryMax = healthCheckRetry ?? 0;
    _healthCheckFailures = 0;
    _healthCheckHost = null;
    _healthCheckTimeoutSec = healthCheckTimeoutSec ?? 5;
    _healthCheckTimer?.cancel();

    _subscription = bridge.messages.listen(
      _handleMessage,
      onError: (err, __) {
        _log('Stream error: $err', level: Level.WARNING);
        state = state.copyWith(error: err.toString(), connected: false);
      },
      onDone: () {
        _log('Stream closed');
        state = state.copyWith(isRunning: false, connected: false);
      },
      cancelOnError: false,
    );

    try {
      await bridge.start(
        pollIntervalSec: pollIntervalSec,
        healthCheckSec: healthCheckSec,
        healthCheckRetry: healthCheckRetry,
        healthCheckTimeoutSec: healthCheckTimeoutSec,
        method: coordinatorDiscoveryMethod ?? 'lmp_zgs',
      );
      state = state.copyWith(
        isRunning: true,
        connected: true,
        clearError: true,
      );
    } catch (e) {
      _log('Failed to start native Sonos bridge: $e', level: Level.WARNING);
      state = state.copyWith(
        error: e.toString(),
        connected: false,
        isRunning: false,
        clearPayload: true,
      );
      await stop();
    }
  }

  Future<void> stop() async {
    _log('Stopping native Sonos bridge');
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _healthCheckHost = null;
    _healthCheckFailures = 0;
    _healthCheckIntervalSec = 0;
    _healthCheckRetryMax = 0;
    _healthCheckTimeoutSec = 5;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _bridge?.stop();
    } catch (e) {
      _log('Error stopping native Sonos bridge: $e', level: Level.WARNING);
    }
    _bridge = null;
    state = state.copyWith(
      isRunning: false,
      connected: false,
      clearPayload: true,
      clearError: true,
    );
  }

  Future<bool> probe(
      {bool forceRediscover = false,
      String? coordinatorDiscoveryMethod}) async {
    final bridge = _bridge ??= createNativeSonosBridge();
    _log(
        'Probe requested (supported=${bridge.isSupported}, type=${bridge.runtimeType})',
        level: Level.FINE);
    if (!bridge.isSupported) return false;
    try {
      // _log('Probing native Sonos bridge for devices/coordinator');
      final result = await bridge.probe(
        forceRediscover: forceRediscover,
        method: coordinatorDiscoveryMethod ?? 'lmp_zgs',
      );
      _log('Probe result: ${result ? 'success' : 'no devices'}');
      if (!result) {
        // No devices found: stop any ongoing health checks tied to stale hosts
        // so we don't keep probing unreachable addresses until a new discovery
        // succeeds.
        _healthCheckTimer?.cancel();
        _healthCheckTimer = null;
        _healthCheckHost = null;
      }
      return result;
    } catch (e) {
      _log('Probe failed: $e', level: Level.WARNING);
      _healthCheckTimer?.cancel();
      _healthCheckTimer = null;
      _healthCheckHost = null;
      return false;
    }
  }

  void _handleMessage(NativeSonosMessage message) {
    // Ignore stray messages after the bridge has been stopped. Without this,
    // late payloads can flip state back to connected=true and block a fresh
    // start when Sonos is re-enabled.
    if (!state.isRunning) {
      _log('Ignoring native Sonos message because bridge is not running',
          level: Level.FINE);
      return;
    }

    if (message.serviceStatus != null) {
      _log('Service status: ${message.serviceStatus}');
    }

    if (message.payload != null) {
      if (!_isCoordinatorPayload(message.payload!)) {
        _log('Payload missing coordinator device; treating as failure',
            level: Level.WARNING);
        _logPayloadSummary(message.payload!);
        state = state.copyWith(
          error: 'Coordinator device not found',
          connected: false,
          clearPayload: true,
        );
      } else {
        final coordinatorName = _coordinatorName(message.payload!);
        if (coordinatorName != null) {
          _log('Using coordinator: $coordinatorName');
        }
        _logPayloadSummary(message.payload!);
        state = state.copyWith(
          payload: message.payload,
          connected: true,
          clearError: true,
        );

        // Start shared health checks once we know the coordinator host.
        final host = _coordinatorHost(message.payload!);
        if (_healthCheckIntervalSec > 0 && host != null) {
          _startHealthChecks(host);
        }
      }
    }

    if (message.error != null) {
      _log('Error message: ${message.error}', level: Level.WARNING);
      state = state.copyWith(
        error: message.error,
        connected: false,
        isRunning: false,
        clearPayload: true,
      );
    }

    if (message.payload == null &&
        message.error == null &&
        message.serviceStatus == null) {
      _log('Message received with no payload/status/error; ignoring',
          level: Level.FINE);
    }
  }

  void _startHealthChecks(String host) {
    if (_healthCheckHost == host && _healthCheckTimer != null) return;

    _healthCheckHost = host;
    _healthCheckFailures = 0;
    _healthCheckTimer?.cancel();

    _healthCheckTimer = Timer.periodic(
        Duration(seconds: _healthCheckIntervalSec),
        (_) => _performHealthCheck());
    _log(
        'Health checks enabled host=$host interval=${_healthCheckIntervalSec}s retryMax=$_healthCheckRetryMax',
        level: Level.FINE);
  }

  Future<void> _performHealthCheck() async {
    if (_healthCheckIntervalSec <= 0) return;
    final host = _healthCheckHost;
    if (host == null) return;

    try {
      _log('Performing health check for native Sonos bridge at $host:1400',
          level: Level.FINE);
      final socket = await Socket.connect(host, 1400,
          timeout: Duration(seconds: _healthCheckTimeoutSec));
      socket.destroy();
      if (_healthCheckFailures != 0) {
        _log('Health check recovered after $_healthCheckFailures failures',
            level: Level.FINE);
      }
      _healthCheckFailures = 0;
    } catch (e) {
      _healthCheckFailures += 1;
      _log(
          'Health check failed (#$_healthCheckFailures/$_healthCheckRetryMax): $e',
          level: Level.FINE);

      if (_healthCheckRetryMax > 0 &&
          _healthCheckFailures >= _healthCheckRetryMax &&
          state.connected) {
        _log(
            'Health check retry limit reached; marking native Sonos disconnected',
            level: Level.WARNING);
        _healthCheckTimer?.cancel();
        _healthCheckTimer = null;
        _healthCheckHost = null;
        _healthCheckIntervalSec = 0;
        try {
          await _bridge?.stop();
        } catch (e) {
          _log('Error stopping bridge after health check failure: $e',
              level: Level.WARNING);
        }
        _bridge = null;
        state = state.copyWith(
          connected: false,
          isRunning: false,
          error: 'health_check_failed',
          clearPayload: true,
        );
      }
    }
  }
}

final nativeSonosProvider =
    NotifierProvider<NativeSonosNotifier, NativeSonosState>(() {
  return NativeSonosNotifier();
});
