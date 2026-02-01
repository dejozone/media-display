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
  List<Map<String, dynamic>>? _cachedIdentities;

  /// Last identities payload returned alongside settings.
  /// Empty when not yet fetched or when API does not return identities.
  List<Map<String, dynamic>> get cachedIdentities =>
      _cachedIdentities ?? const [];

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
    // Force next fetch to refresh identities because update response typically
    // does not include them and they may have changed (e.g., Spotify removed).
    _cachedIdentities = null;
    _inflightFetch = null;
    return updated;
  }

  Future<Map<String, dynamic>> _fetchSettingsRemoteForUser(
      String userId) async {
    final res =
        await _dio.get<Map<String, dynamic>>('/api/users/$userId/settings');
    final data = res.data ?? {};

    // Capture identities when present so other parts of the app can know
    // which providers are already linked.
    final identitiesRaw = data['identities'];
    if (identitiesRaw is List) {
      _cachedIdentities = identitiesRaw
          .whereType<Map>()
          .map((entry) => entry.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }

    return data['settings'] as Map<String, dynamic>? ?? {};
  }

  /// Prime the local caches with data fetched elsewhere to avoid extra
  /// network calls (e.g., when Account page already retrieved settings).
  void primeCache({
    required Map<String, dynamic> settings,
    List<Map<String, dynamic>>? identities,
  }) {
    _cachedSettings = settings;
    _cachedIdentities = identities;
    _inflightFetch = null;
  }

  Future<Map<String, dynamic>> _updateSettingsRemoteForUser(
      String userId, Map<String, dynamic> partial) async {
    final res = await _dio.put<Map<String, dynamic>>(
        '/api/users/$userId/settings',
        data: partial);
    final data = res.data ?? {};

    // Capture identities if the API returns them on update.
    final identitiesRaw = data['identities'];
    if (identitiesRaw is List) {
      _cachedIdentities = identitiesRaw
          .whereType<Map>()
          .map((entry) => entry.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }

    return data['settings'] as Map<String, dynamic>? ?? {};
  }
}
