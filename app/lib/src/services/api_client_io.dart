import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
  final envConfig = env;
  var clearingAuth = false;
  var refreshing = false;

  Future<String?> refreshToken() async {
    if (refreshing) return null;
    refreshing = true;
    try {
      final refreshDio = Dio(BaseOptions(
        baseUrl: envConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        extra: {'withCredentials': true},
      ));
      final resp = await refreshDio.post('/api/auth/refresh');
      final data = resp.data;
      final token =
          (data is Map<String, dynamic>) ? data['jwt'] as String? : null;
      if (token != null && token.isNotEmpty) {
        await tokenStorage.save(token);
        await authNotifier.setToken(token);
        return token;
      }
    } catch (_) {
      // swallow
    } finally {
      refreshing = false;
    }
    return null;
  }

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

  if (!env.apiSslVerify) {
    final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
    adapter.createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      return client;
    };
  }

  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      options.extra['withCredentials'] = true;
      final token = await tokenStorage.load();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      return handler.next(options);
    },
    onError: (e, handler) async {
      final req = e.requestOptions;
      final alreadyRetried = req.extra['retried'] == true;
      final isAuthEndpoint = req.path.contains('/api/auth/refresh');
      if (isUnauthorized(e) && !alreadyRetried && !isAuthEndpoint) {
        final newToken = await refreshToken();
        if (newToken != null && newToken.isNotEmpty) {
          final clone = await tokenStorage.load();
          req.headers['Authorization'] = clone != null ? 'Bearer $clone' : null;
          req.extra['retried'] = true;
          try {
            final retryResp = await dio.fetch(req);
            return handler.resolve(retryResp);
          } catch (err) {
            // fallthrough
          }
        }
        await clearAuth();
      }
      return handler.next(e);
    },
  ));

  return dio;
});
