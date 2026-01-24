import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Client for Spotify Web API
class SpotifyApiClient {
  SpotifyApiClient({http.Client? httpClient, bool sslVerify = true})
      : _client = httpClient ?? _createClient(sslVerify);

  final http.Client _client;

  static http.Client _createClient(bool sslVerify) {
    if (sslVerify) {
      return http.Client();
    }
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return IOClient(httpClient);
  }

  /// Fetches the current user's playback state from Spotify Web API
  /// Returns null if no active playback, throws on errors
  Future<Map<String, dynamic>?> getCurrentPlayback(String accessToken) async {
    final uri = Uri.parse('https://api.spotify.com/v1/me/player');
    final response = await _client.get(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 204) {
      // No active playback
      return null;
    }

    if (response.statusCode == 401) {
      throw SpotifyApiException(
        'Unauthorized',
        statusCode: 401,
        isAuthError: true,
      );
    }

    if (response.statusCode != 200) {
      throw SpotifyApiException(
        'HTTP ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void dispose() {
    _client.close();
  }
}

class SpotifyApiException implements Exception {
  SpotifyApiException(
    this.message, {
    this.statusCode,
    this.isAuthError = false,
  });

  final String message;
  final int? statusCode;
  final bool isAuthError;

  @override
  String toString() => 'SpotifyApiException: $message';
}
