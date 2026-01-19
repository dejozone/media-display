import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/api_client.dart';

final settingsServiceProvider = Provider<SettingsService>((ref) {
  final dio = ref.watch(dioProvider);
  return SettingsService(dio);
});

class SettingsService {
  SettingsService(this._dio);
  final Dio _dio;

  Future<Map<String, dynamic>> fetchSettings() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/settings');
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> partial) async {
    final res = await _dio.put<Map<String, dynamic>>('/api/settings', data: partial);
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }
}
