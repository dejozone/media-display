import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/api_client.dart';

final accountServiceProvider = Provider<AccountService>((ref) {
  final dio = ref.watch(dioProvider);
  return AccountService(dio);
});

class AccountService {
  AccountService(this._dio);
  final Dio _dio;

  Future<Map<String, dynamic>> fetchAccount() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/users/me');
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> fetchSettings(String userId) async {
    final res =
        await _dio.get<Map<String, dynamic>>('/api/users/$userId/settings');
    final data = res.data ?? {};
    return {
      'settings': data['settings'] as Map<String, dynamic>? ?? {},
      'user': data['user'] as Map<String, dynamic>? ?? {},
      'identities': data['identities'] as List<dynamic>? ?? const [],
    };
  }

  Future<Map<String, dynamic>> updateAccount(
      String userId, Map<String, dynamic> payload) async {
    final res = await _dio.put<Map<String, dynamic>>('/api/users/$userId',
        data: payload);
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> updateService(
      {required String userId,
      required String service,
      required bool enable}) async {
    final path = '/api/users/$userId/services/$service';
    final res = enable
        ? await _dio.post<Map<String, dynamic>>(path)
        : await _dio.delete<Map<String, dynamic>>(path);
    // Some endpoints return settings; prefer user if present
    final user = res.data?['user'];
    if (user is Map<String, dynamic>) return user;
    return {};
  }

  Future<Map<String, dynamic>> saveAvatar(
      {required String userId,
      required String avatarUrl,
      String? avatarProvider}) async {
    final res = await _dio.put<Map<String, dynamic>>(
      '/api/users/$userId',
      data: {
        'avatar_url': avatarUrl,
        if (avatarProvider != null) 'avatar_provider': avatarProvider,
      },
    );
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }
}
