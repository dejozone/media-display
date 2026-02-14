import 'dart:async';

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

  bool _isCoordinatorPayload(Map<String, dynamic> payload) {
    // Check common shapes for a coordinator flag in the payload
    final direct =
        payload['coordinator'] == true || payload['isCoordinator'] == true;
    final group = payload['group'];
    final groupCoordinator = group is Map<String, dynamic>
        ? (group['coordinator'] == true || group['isCoordinator'] == true)
        : false;
    final player = payload['player'];
    final playerCoordinator = player is Map<String, dynamic>
        ? (player['coordinator'] == true || player['isCoordinator'] == true)
        : false;
    return direct || groupCoordinator || playerCoordinator;
  }

  void _logPayloadSummary(Map<String, dynamic> payload) {
    final player = payload['player'];
    final playerName = player is Map<String, dynamic>
        ? (player['name'] ?? player['title'] ?? player['displayName'])
        : null;
    final playerIsCoordinator = player is Map<String, dynamic>
        ? (player['coordinator'] == true || player['isCoordinator'] == true)
        : null;

    final group = payload['group'];
    final groupName = group is Map<String, dynamic>
        ? (group['coordinatorName'] ?? group['name'])
        : null;
    final groupIsCoordinator = group is Map<String, dynamic>
        ? (group['coordinator'] == true || group['isCoordinator'] == true)
        : null;

    final keys = payload.keys.join(',');
    _log(
        'Native Sonos payload summary: keys=[$keys], player=$playerName (isCoordinator=$playerIsCoordinator), group=$groupName (isCoordinator=$groupIsCoordinator)');
  }

  String? _coordinatorName(Map<String, dynamic> payload) {
    // Try common fields for identifying the coordinator device name
    final player = payload['player'];
    if (player is Map<String, dynamic>) {
      final name = player['name'] ?? player['title'] ?? player['displayName'];
      if (name is String && name.isNotEmpty) return name;
    }

    final group = payload['group'];
    if (group is Map<String, dynamic>) {
      final name = group['coordinatorName'] ?? group['name'];
      if (name is String && name.isNotEmpty) return name;
    }

    final device = payload['device'];
    if (device is Map<String, dynamic>) {
      final name = device['name'] ?? device['displayName'];
      if (name is String && name.isNotEmpty) return name;
    }

    final friendly = payload['friendlyName'];
    if (friendly is String && friendly.isNotEmpty) return friendly;

    return null;
  }

  @override
  NativeSonosState build() {
    ref.onDispose(() async {
      await stop();
    });
    return const NativeSonosState();
  }

  Future<void> start({int? pollIntervalSec}) async {
    await stop();

    final bridge = _bridge ??= createNativeSonosBridge();
    _log(
        'Native Sonos bridge created (supported=${bridge.isSupported}, type=${bridge.runtimeType})',
        level: Level.FINE);
    if (!bridge.isSupported) {
      _log(
          'Native Sonos bridge not available on this platform; falling back to local Sonos if enabled',
          level: Level.WARNING);
      state = state.copyWith(
        error: 'Native Sonos bridge not available on this platform',
        connected: false,
        isRunning: false,
      );
      return;
    }

    _log('Starting native Sonos bridge (pollIntervalSec=$pollIntervalSec)');

    // Mark running immediately to avoid transient "not connected" fallbacks
    // while the bridge initializes.
    state = state.copyWith(isRunning: true, connected: false, clearError: true);

    _subscription = bridge.messages.listen(
      _handleMessage,
      onError: (err, __) {
        _log('Native Sonos stream error: $err', level: Level.WARNING);
        state = state.copyWith(error: err.toString(), connected: false);
      },
      onDone: () {
        _log('Native Sonos stream closed');
        state = state.copyWith(isRunning: false, connected: false);
      },
      cancelOnError: false,
    );

    try {
      await bridge.start(pollIntervalSec: pollIntervalSec);
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
      );
      await stop();
    }
  }

  Future<void> stop() async {
    _log('Stopping native Sonos bridge');
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _bridge?.stop();
    } catch (e) {
      _log('Error stopping native Sonos bridge: $e', level: Level.WARNING);
    }
    state = state.copyWith(isRunning: false, connected: false);
  }

  Future<bool> probe() async {
    final bridge = _bridge ??= createNativeSonosBridge();
    _log(
        'Probe requested (supported=${bridge.isSupported}, type=${bridge.runtimeType})',
        level: Level.FINE);
    if (!bridge.isSupported) return false;
    try {
      _log('Probing native Sonos bridge for devices/coordinator');
      final result = await bridge.probe();
      _log('Native Sonos probe result: ${result ? 'success' : 'no devices'}');
      return result;
    } catch (e) {
      _log('Probe failed: $e', level: Level.WARNING);
      return false;
    }
  }

  void _handleMessage(NativeSonosMessage message) {
    if (message.serviceStatus != null) {
      _log('Native Sonos serviceStatus: ${message.serviceStatus}');
    }

    if (message.payload != null) {
      if (!_isCoordinatorPayload(message.payload!)) {
        _log(
            'Native Sonos payload missing coordinator device; treating as failure',
            level: Level.WARNING);
        _logPayloadSummary(message.payload!);
        state = state.copyWith(
          error: 'Coordinator device not found',
          connected: false,
          clearPayload: true,
        );
      } else {
        _log(
            'Native Sonos payload received (keys=${message.payload!.keys.join(',')})',
            level: Level.FINE);
        final coordinatorName = _coordinatorName(message.payload!);
        if (coordinatorName != null) {
          _log('Native Sonos coordinator detected: $coordinatorName');
        }
        _logPayloadSummary(message.payload!);
        state = state.copyWith(
          payload: message.payload,
          connected: true,
          clearError: true,
        );
      }
    }

    if (message.error != null) {
      _log('Native Sonos error message: ${message.error}',
          level: Level.WARNING);
      state = state.copyWith(
        error: message.error,
        connected: false,
      );
    }

    if (message.payload == null &&
        message.error == null &&
        message.serviceStatus == null) {
      _log(
          'Native Sonos message received with no payload/status/error; ignoring',
          level: Level.FINE);
    }
  }
}

final nativeSonosProvider =
    NotifierProvider<NativeSonosNotifier, NativeSonosState>(() {
  return NativeSonosNotifier();
});
