import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/api_client.dart';
import 'package:media_display/src/services/token_storage.dart';
import 'package:media_display/src/services/auth_state.dart';

final authServiceProvider = Provider<AuthService>((ref) {
  final dio = ref.watch(dioProvider);
  final auth = ref.read(authStateProvider.notifier);
  return AuthService(dio, TokenStorage(), auth);
});

class AuthService {
  AuthService(this._dio, this._storage, this._authNotifier);

  final Dio _dio;
  final TokenStorage _storage;
  final AuthNotifier _authNotifier;

  Future<Uri> getGoogleAuthUrl() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/auth/google/url');
    final data = res.data ?? {};
    final url = data['url'] as String?;
    if (url == null) throw Exception('Missing auth URL');
    return Uri.parse(url);
  }

  Future<Uri> getSpotifyAuthUrl() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/auth/spotify/url');
    final data = res.data ?? {};
    final url = data['url'] as String?;
    if (url == null) throw Exception('Missing auth URL');
    return Uri.parse(url);
  }

  Future<void> completeOAuth({required String provider, required String code, String? state}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/api/auth/$provider/callback',
        queryParameters: {'code': code, 'state': state},
      );
      final data = res.data ?? {};
      final token = data['jwt'] as String?;
      if (token == null) throw Exception('Missing token');
      await _storage.save(token);
      await _authNotifier.setToken(token);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final payload = e.response?.data;
      if (status == 409 && payload is Map<String, dynamic>) {
        final codeVal = payload['code']?.toString();
        final msgVal = payload['error']?.toString() ?? payload['message']?.toString();
        if (codeVal != null) {
          throw OAuthApiException(code: codeVal, message: msgVal, status: status);
        }
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    await _authNotifier.clear();
  }
}

class OAuthApiException implements Exception {
  OAuthApiException({required this.code, this.message, this.status});

  final String code;
  final String? message;
  final int? status;

  @override
  String toString() => 'OAuthApiException(code: $code, message: $message, status: $status)';
}
