import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/app.dart';
import 'package:media_display/src/config/env.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await loadEnv();
  runApp(const ProviderScope(child: MediaDisplayApp()));
}
