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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
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
