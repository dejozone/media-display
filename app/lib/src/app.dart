import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/routing/router.dart';

class MediaDisplayApp extends ConsumerWidget {
  const MediaDisplayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final env = ref.watch(envConfigProvider);
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Media Display',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5AC8FA),
          brightness: Brightness.dark,
          background: const Color(0xFF0E1117),
          surface: const Color(0xFF111624),
          primary: const Color(0xFF5AC8FA),
          secondary: const Color(0xFF4B7BEC),
          tertiary: const Color(0xFF9FB1D0),
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardColor: const Color(0xFF111624),
        textTheme: ThemeData.dark().textTheme,
      ),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Banner(
          message: env.flavor,
          location: BannerLocation.topStart,
          color: Colors.indigo,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
