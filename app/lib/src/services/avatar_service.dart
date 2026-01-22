import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/models/avatar.dart';
import 'package:media_display/src/services/auth_state.dart';

class AvatarService {
  AvatarService({required this.apiBaseUrl, required this.getToken});

  final String apiBaseUrl;
  final String? Function() getToken;

  /// Fetch all avatars for the current user
  Future<List<Avatar>> fetchAvatars(String userId) async {
    final token = getToken();
    if (token == null) {
      throw Exception('Not authenticated');
    }

    final url = Uri.parse('$apiBaseUrl/api/users/$userId/avatars');
    final response = await http.get(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      print('🔍 DEBUG: Raw avatars response: ${response.body}');

      final avatarsList = data['avatars'] as List;
      print('🔍 DEBUG: Avatars list length: ${avatarsList.length}');

      final avatars = <Avatar>[];
      for (var i = 0; i < avatarsList.length; i++) {
        try {
          final json = avatarsList[i] as Map<String, dynamic>;
          print('🔍 DEBUG: Parsing avatar $i: $json');
          final avatar = Avatar.fromJson(json);
          avatars.add(avatar);
        } catch (e, stack) {
          print('❌ ERROR: Failed to parse avatar $i: $e');
          print('Stack trace: $stack');
          print('JSON data: ${avatarsList[i]}');
          rethrow;
        }
      }

      return avatars;
    } else {
      throw Exception('Failed to fetch avatars: ${response.statusCode}');
    }
  }

  /// Get the selected avatar for the current user
  Future<Avatar?> fetchSelectedAvatar(String userId) async {
    final avatars = await fetchAvatars(userId);
    return avatars.where((a) => a.isSelected).firstOrNull;
  }

  /// Upload a new avatar image from bytes
  Future<Avatar> uploadAvatarBytes(
      String userId, Uint8List bytes, String filename) async {
    final token = getToken();
    if (token == null) {
      throw Exception('Not authenticated');
    }

    final url = Uri.parse('$apiBaseUrl/api/users/$userId/avatars');
    final request = http.MultipartRequest('POST', url);
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: filename,
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body);
      return Avatar.fromJson(data['avatar'] as Map<String, dynamic>);
    } else {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? 'Failed to upload avatar');
    }
  }

  /// Select an avatar (make it the active one)
  Future<Avatar> selectAvatar(String userId, String avatarId) async {
    final token = getToken();
    if (token == null) {
      throw Exception('Not authenticated');
    }

    final url = Uri.parse('$apiBaseUrl/api/users/$userId/avatars/$avatarId');
    final response = await http.patch(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'is_selected': true}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Avatar.fromJson(data['avatar'] as Map<String, dynamic>);
    } else {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? 'Failed to select avatar');
    }
  }

  /// Delete an avatar
  Future<void> deleteAvatar(String userId, String avatarId) async {
    final token = getToken();
    if (token == null) {
      throw Exception('Not authenticated');
    }

    final url = Uri.parse('$apiBaseUrl/api/users/$userId/avatars/$avatarId');
    final response = await http.delete(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? 'Failed to delete avatar');
    }
  }
}

/// Provider for AvatarService
final avatarServiceProvider = Provider<AvatarService>((ref) {
  final env = ref.watch(envConfigProvider);
  final authState = ref.watch(authStateProvider);
  return AvatarService(
    apiBaseUrl: env.apiBaseUrl,
    getToken: () => authState.token,
  );
});

/// Provider for fetching avatars for a user
final avatarsProvider = FutureProvider.autoDispose
    .family<List<Avatar>, String>((ref, userId) async {
  final service = ref.watch(avatarServiceProvider);
  return await service.fetchAvatars(userId);
});

/// Provider for the selected avatar only
final selectedAvatarProvider = Provider.family<Avatar?, String>((ref, userId) {
  final avatarsAsync = ref.watch(avatarsProvider(userId));
  return avatarsAsync.whenOrNull(
    data: (avatars) => avatars.where((a) => a.isSelected).firstOrNull,
  );
});

/// Helper class for avatar operations that trigger provider refresh
class AvatarOperations {
  const AvatarOperations(this.ref, this.service);

  final Ref ref;
  final AvatarService service;

  /// Upload a new avatar from bytes and refresh the provider
  Future<Avatar> uploadAvatarBytes(
      String userId, Uint8List bytes, String filename) async {
    final avatar = await service.uploadAvatarBytes(userId, bytes, filename);
    ref.invalidate(avatarsProvider(userId));
    return avatar;
  }

  /// Select an avatar and refresh the provider
  Future<Avatar> selectAvatar(String userId, String avatarId) async {
    final avatar = await service.selectAvatar(userId, avatarId);
    ref.invalidate(avatarsProvider(userId));
    return avatar;
  }

  /// Delete an avatar and refresh the provider
  Future<void> deleteAvatar(String userId, String avatarId) async {
    await service.deleteAvatar(userId, avatarId);
    ref.invalidate(avatarsProvider(userId));
  }
}

/// Provider for avatar operations
final avatarOperationsProvider = Provider((ref) {
  final service = ref.watch(avatarServiceProvider);
  return AvatarOperations(ref, service);
});
