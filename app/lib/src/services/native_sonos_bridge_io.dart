import 'dart:io' show Platform;

import 'package:media_display/src/services/native_sonos_bridge_macos.dart'
    as macos_bridge;
import 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    as stub_bridge;

export 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    show NativeSonosMessage;

/// Factory-resolved bridge for non-web platforms.
/// On macOS, uses the native SSDP-based bridge; otherwise falls back to stub.
class NativeSonosBridge {
  NativeSonosBridge()
      : _macos = Platform.isMacOS ? macos_bridge.NativeSonosBridge() : null,
        _stub = Platform.isMacOS ? null : stub_bridge.NativeSonosBridge();

  final macos_bridge.NativeSonosBridge? _macos;
  final stub_bridge.NativeSonosBridge? _stub;

  bool get isSupported => _macos?.isSupported ?? false;

  Stream<stub_bridge.NativeSonosMessage> get messages =>
      (_macos?.messages ?? _stub?.messages) ?? const Stream.empty();

  Future<void> start(
      {int? pollIntervalSec,
      int? trackProgressPollIntervalSec,
      bool enableTrackProgress = false,
      int? healthCheckSec,
      int? healthCheckRetry,
      int? healthCheckTimeoutSec,
      String method = 'lmp_zgs',
      int? maxHostsPerDiscovery}) {
    return _macos?.start(
          pollIntervalSec: pollIntervalSec,
          trackProgressPollIntervalSec: trackProgressPollIntervalSec,
          enableTrackProgress: enableTrackProgress,
          healthCheckSec: healthCheckSec,
          healthCheckRetry: healthCheckRetry,
          healthCheckTimeoutSec: healthCheckTimeoutSec,
          method: method,
          maxHostsPerDiscovery: maxHostsPerDiscovery,
        ) ??
        _stub?.start(
          pollIntervalSec: pollIntervalSec,
          trackProgressPollIntervalSec: trackProgressPollIntervalSec,
          enableTrackProgress: enableTrackProgress,
          healthCheckSec: healthCheckSec,
          healthCheckRetry: healthCheckRetry,
          healthCheckTimeoutSec: healthCheckTimeoutSec,
          method: method,
          maxHostsPerDiscovery: maxHostsPerDiscovery,
        ) ??
        Future.value();
  }

  Future<void> stop() {
    return _macos?.stop() ?? _stub?.stop() ?? Future.value();
  }

  Future<bool> probe(
      {bool forceRediscover = false,
      String method = 'lmp_zgs',
      int? maxHostsPerDiscovery}) {
    return _macos?.probe(
          forceRediscover: forceRediscover,
          method: method,
          maxHostsPerDiscovery: maxHostsPerDiscovery,
        ) ??
        _stub?.probe(
          forceRediscover: forceRediscover,
          method: method,
          maxHostsPerDiscovery: maxHostsPerDiscovery,
        ) ??
        Future.value(false);
  }
}
