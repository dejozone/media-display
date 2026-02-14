// Stub implementation for platforms without a native Sonos bridge.
// Replace with platform-specific bridge (e.g., MethodChannel/FFI) on supported targets.

class NativeSonosMessage {
  NativeSonosMessage({this.payload, this.serviceStatus, this.error});

  /// Normalized now_playing payload (same shape as backend Sonos).
  final Map<String, dynamic>? payload;

  /// Optional service_status message (same shape as backend health).
  final Map<String, dynamic>? serviceStatus;

  /// Error message, if any.
  final String? error;
}

class NativeSonosBridge {
  NativeSonosBridge({bool enableProgress = true});
  bool get isSupported => false; // Stub: no native bridge available

  Stream<NativeSonosMessage> get messages => const Stream.empty();

  Future<void> start({int? pollIntervalSec}) async {
    // No-op stub; replace with platform-specific bridge.
  }

  Future<void> stop() async {}

  Future<bool> probe() async => false;
}
