import 'dart:typed_data';

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
    final res = await _dio.get<Map<String, dynamic>>('/api/account');
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> fetchSettings() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/settings');
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> updateAccount(Map<String, dynamic> payload) async {
    final res = await _dio.put<Map<String, dynamic>>('/api/account', data: payload);
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> updateService({required String userId, required String service, required bool enable}) async {
    final path = '/api/users/$userId/services/$service';
    final res = enable
        ? await _dio.post<Map<String, dynamic>>(path)
        : await _dio.delete<Map<String, dynamic>>(path);
    // Some endpoints return settings; prefer user if present
    final user = res.data?['user'];
    if (user is Map<String, dynamic>) return user;
    return {};
  }

  Future<Map<String, dynamic>> saveAvatar({required String avatarUrl, String? avatarProvider}) async {
    final res = await _dio.put<Map<String, dynamic>>(
      '/api/account',
      data: {
        'avatar_url': avatarUrl,
        if (avatarProvider != null) 'avatar_provider': avatarProvider,
      },
    );
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }

  Future<String> uploadAvatarBytes({required Uint8List bytes, required String filename}) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/account/avatar',
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
    return res.data?['avatar_url']?.toString() ?? '';
  }
}
