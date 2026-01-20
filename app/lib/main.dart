import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart' show webPluginRegistrar;
import 'package:flutter_web_plugins/url_strategy.dart' show usePathUrlStrategy;
import 'package:image_picker_for_web/image_picker_for_web.dart';
import 'package:media_display/src/app.dart';
import 'package:media_display/src/config/env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) _registerWebPlugins();
  usePathUrlStrategy();
  await loadEnv();
  runApp(const ProviderScope(child: MediaDisplayApp()));
}

void _registerWebPlugins() {
  final registrar = webPluginRegistrar;
  ImagePickerPlugin.registerWith(registrar);
  registrar.registerMessageHandler();
}
