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

  Map<String, dynamic>? _cachedUser;
  Future<Map<String, dynamic>>? _inflightFetch;

  Future<Map<String, dynamic>> fetchMe({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      if (_cachedUser != null) return _cachedUser!;
      if (_inflightFetch != null) return _inflightFetch!;
    }

    _inflightFetch = _fetchMeRemote();
    try {
      final data = await _inflightFetch!;
      _cachedUser = data;
      return data;
    } finally {
      _inflightFetch = null;
    }
  }

  Future<Map<String, dynamic>> _fetchMeRemote() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/users/me');
    return res.data?['user'] as Map<String, dynamic>? ?? {};
  }

  void clearCache() {
    _cachedUser = null;
    _inflightFetch = null;
  }
}
