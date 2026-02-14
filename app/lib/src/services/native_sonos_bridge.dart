import 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    if (dart.library.html) 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    if (dart.library.io) 'package:media_display/src/services/native_sonos_bridge_io.dart';

// Re-export the common types so consumers can reference NativeSonosMessage.
export 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    if (dart.library.html) 'package:media_display/src/services/native_sonos_bridge_stub.dart'
    if (dart.library.io) 'package:media_display/src/services/native_sonos_bridge_io.dart';

// Factory for platform-specific NativeSonosBridge.
NativeSonosBridge createNativeSonosBridge({bool enableProgress = true}) =>
    NativeSonosBridge(enableProgress: enableProgress);
