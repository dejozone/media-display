import 'dart:io' show Platform;

import 'package:media_display/src/services/native_sonos_bridge_linux.dart'
    as linux_bridge;
import 'package:media_display/src/services/native_sonos_bridge_macos.dart'
    as macos_bridge;
import 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    as stub_bridge;
import 'package:media_display/src/services/native_sonos_bridge_windows.dart'
    as windows_bridge;

export 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    show NativeSonosMessage;

/// Factory-resolved bridge for non-web platforms.
/// Desktop path:
/// - macOS uses a compatibility shim that forwards to the neutral desktop adapter
/// - Linux/Windows use desktop adapters directly
///
/// Mobile path:
/// - Android/iOS remain behind compile-time feature flags
/// - when disabled, fallback is the stub bridge
class NativeSonosBridge {
  static const bool _enableAndroidNativeSonos =
      bool.fromEnvironment('ENABLE_NATIVE_SONOS_ANDROID', defaultValue: false);
  static const bool _enableIosNativeSonos =
      bool.fromEnvironment('ENABLE_NATIVE_SONOS_IOS', defaultValue: false);

  NativeSonosBridge()
      : _macosShim = Platform.isMacOS ? macos_bridge.NativeSonosBridge() : null,
        _linuxDesktop =
            Platform.isLinux ? linux_bridge.NativeSonosBridge() : null,
        _windowsDesktop =
            Platform.isWindows ? windows_bridge.NativeSonosBridge() : null,
        _stub = _shouldUseStub ? stub_bridge.NativeSonosBridge() : null;

  final macos_bridge.NativeSonosBridge? _macosShim;
  final linux_bridge.NativeSonosBridge? _linuxDesktop;
  final windows_bridge.NativeSonosBridge? _windowsDesktop;
  final stub_bridge.NativeSonosBridge? _stub;

  static bool get _desktopSupported =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  static bool get _mobileEnabled =>
      (Platform.isAndroid && _enableAndroidNativeSonos) ||
      (Platform.isIOS && _enableIosNativeSonos);

  static bool get _shouldUseStub =>
      !_desktopSupported ||
      ((Platform.isAndroid || Platform.isIOS) && !_mobileEnabled);

  dynamic get _selectedBridge =>
      _macosShim ?? _linuxDesktop ?? _windowsDesktop ?? _stub;

  bool get isSupported => _selectedBridge?.isSupported ?? false;

  Stream<stub_bridge.NativeSonosMessage> get messages =>
      (_selectedBridge?.messages as Stream<stub_bridge.NativeSonosMessage>?) ??
      const Stream.empty();

  Future<void> start(
      {int? pollIntervalSec,
      int? trackProgressPollIntervalSec,
      bool enableTrackProgress = false,
      int? healthCheckSec,
      int? healthCheckRetry,
      int? healthCheckTimeoutSec,
      String method = 'lmp_zgs',
      int? maxHostsPerDiscovery}) {
    return _selectedBridge?.start(
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
    return _selectedBridge?.stop() ?? Future.value();
  }

  Future<void> setTrackProgressPolling(
      {required bool enabled, int? intervalSec}) {
    return _selectedBridge?.setTrackProgressPolling(
          enabled: enabled,
          intervalSec: intervalSec,
        ) ??
        Future.value();
  }

  Future<bool> probe(
      {bool forceRediscover = false,
      String method = 'lmp_zgs',
      int? maxHostsPerDiscovery}) {
    return _selectedBridge?.probe(
          forceRediscover: forceRediscover,
          method: method,
          maxHostsPerDiscovery: maxHostsPerDiscovery,
        ) ??
        Future.value(false);
  }
}
