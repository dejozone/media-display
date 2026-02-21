import 'dart:io' show Platform;

import 'package:media_display/src/services/native_sonos_bridge_desktop.dart'
    as desktop_bridge;

/// macOS compatibility shim over the neutral desktop Sonos bridge.
class NativeSonosBridge extends desktop_bridge.NativeSonosBridge {
  NativeSonosBridge({
    super.httpTransport,
    super.discoveryAdapter,
    super.protocolParser,
  });

  @override
  bool get isSupported => Platform.isMacOS;
}
