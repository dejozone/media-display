import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/api_client.dart';

final userServiceProvider = Provider<UserService>((ref) {
  final dio = ref.watch(dioProvider);
  return UserService(dio);
});

class UserService {
  UserService(this._dio);
  final Dio _dio;

  Future<Map<String, dynamic>> fetchMe() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/user/me');
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }
}
