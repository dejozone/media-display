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

  Map<String, dynamic>? _cachedSettings;
  Future<Map<String, dynamic>>? _inflightFetch;

  Future<Map<String, dynamic>> fetchSettings(
      {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      if (_cachedSettings != null) return _cachedSettings!;
      if (_inflightFetch != null) return _inflightFetch!;
    }

    _inflightFetch = _fetchSettingsRemote();
    try {
      final data = await _inflightFetch!;
      _cachedSettings = data;
      return data;
    } finally {
      _inflightFetch = null;
    }
  }

  Future<Map<String, dynamic>> updateSettings(
      Map<String, dynamic> partial) async {
    final updated = await _updateSettingsRemote(partial);
    _cachedSettings = updated;
    _inflightFetch = null;
    return updated;
  }

  Future<Map<String, dynamic>> _fetchSettingsRemote() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/settings');
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> _updateSettingsRemote(
      Map<String, dynamic> partial) async {
    final res =
        await _dio.put<Map<String, dynamic>>('/api/settings', data: partial);
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> fetchSettingsForUser(String userId,
      {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      if (_cachedSettings != null) return _cachedSettings!;
      if (_inflightFetch != null) return _inflightFetch!;
    }

    _inflightFetch = _fetchSettingsRemoteForUser(userId);
    try {
      final data = await _inflightFetch!;
      _cachedSettings = data;
      return data;
    } finally {
      _inflightFetch = null;
    }
  }

  Future<Map<String, dynamic>> updateSettingsForUser(
      String userId, Map<String, dynamic> partial) async {
    final updated = await _updateSettingsRemoteForUser(userId, partial);
    _cachedSettings = updated;
    _inflightFetch = null;
    return updated;
  }

  Future<Map<String, dynamic>> _fetchSettingsRemoteForUser(
      String userId) async {
    final res =
        await _dio.get<Map<String, dynamic>>('/api/users/$userId/settings');
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> _updateSettingsRemoteForUser(
      String userId, Map<String, dynamic> partial) async {
    final res = await _dio.put<Map<String, dynamic>>(
        '/api/users/$userId/settings',
        data: partial);
    return res.data?['settings'] as Map<String, dynamic>? ?? {};
  }
}
