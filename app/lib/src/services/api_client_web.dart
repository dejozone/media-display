import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/token_storage.dart';
import 'package:media_display/src/services/auth_state.dart';

final dioProvider = Provider<Dio>((ref) {
  final env = ref.watch(envConfigProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: env.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  final tokenStorage = TokenStorage();
  final authNotifier = ref.read(authStateProvider.notifier);
  var clearingAuth = false;

  bool isUnauthorized(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) return true;
    final data = e.response?.data;
    if (data is String) {
      final lowered = data.toLowerCase();
      return lowered.contains('invalid token') ||
          lowered.contains('jwt') ||
          lowered.contains('unauthorized');
    }
    if (data is Map<String, dynamic>) {
      final msg = data['message']?.toString().toLowerCase();
      final err = data['error']?.toString().toLowerCase();
      return msg?.contains('token') == true || err?.contains('token') == true;
    }
    return false;
  }

  Future<void> clearAuth() async {
    if (clearingAuth) return;
    clearingAuth = true;
    try {
      await tokenStorage.clear();
      await authNotifier.clear();
    } finally {
      clearingAuth = false;
    }
  }

  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await tokenStorage.load();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      return handler.next(options);
    },
    onError: (e, handler) async {
      if (isUnauthorized(e)) {
        await clearAuth();
      }
      return handler.next(e);
    },
  ));

  return dio;
});
