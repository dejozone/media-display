import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class EnvConfig {
  EnvConfig({
    required this.apiBaseUrl,
    required this.eventsWsUrl,
    required this.flavor,
    required this.apiSslVerify,
    required this.eventsWsSslVerify,
    required this.wsRetryIntervalMs,
    required this.wsRetryActiveSeconds,
    required this.wsRetryCooldownSeconds,
    required this.wsRetryMaxTotalSeconds,
    required this.spotifyPollIntervalSec,
    required this.maxAvatarsPerUser,
    required this.spotifyDirectPollIntervalSec,
    required this.spotifyDirectRetryIntervalSec,
    required this.spotifyDirectRetryWindowSec,
    required this.spotifyDirectCooldownSec,
    required this.wsForceReconnIdleSec,
    required this.spotifyDirectApiSslVerify,
    required this.spotifyDirectApiBaseUrl,
    this.sonosPollIntervalSec,
  });

  final String apiBaseUrl;
  final String eventsWsUrl;
  final String flavor;
  final bool apiSslVerify;
  final bool eventsWsSslVerify;
  final int wsRetryIntervalMs;
  final int wsRetryActiveSeconds;
  final int wsRetryCooldownSeconds;
  final int wsRetryMaxTotalSeconds;
  final int spotifyPollIntervalSec;
  final int? sonosPollIntervalSec;
  final int maxAvatarsPerUser;
  final int spotifyDirectPollIntervalSec;
  final int spotifyDirectRetryIntervalSec;
  final int spotifyDirectRetryWindowSec;
  final int spotifyDirectCooldownSec;
  final int wsForceReconnIdleSec;
  final bool spotifyDirectApiSslVerify;
  final String spotifyDirectApiBaseUrl;
}

final envConfigProvider = Provider<EnvConfig>((ref) {
  final api = dotenv.env['API_BASE_URL'] ?? 'http://localhost:5001';
  final ws = dotenv.env['EVENTS_WS_URL'] ?? 'ws://localhost:5002/events/media';
  final flavor = dotenv.env['FLAVOR'] ?? 'dev';
  final apiSslVerify =
      (dotenv.env['API_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsSslVerify =
      (dotenv.env['EVENTS_WS_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsRetryIntervalMs =
      int.tryParse(dotenv.env['WS_RETRY_INTERVAL_MS'] ?? '') ?? 3000;
  final wsRetryActiveSeconds =
      int.tryParse(dotenv.env['WS_RETRY_ACTIVE_SECONDS'] ?? '') ?? 60;
  final wsRetryCooldownSeconds =
      int.tryParse(dotenv.env['WS_RETRY_COOLDOWN_SECONDS'] ?? '') ?? 60;
  final wsRetryMaxTotalSeconds =
      int.tryParse(dotenv.env['WS_RETRY_MAX_TOTAL_SECONDS'] ?? '') ?? 1800;
  final spotifyPollIntervalSec =
      int.tryParse(dotenv.env['SPOTIFY_POLL_INTERVAL_SEC'] ?? '') ?? 3;
  final sonosPollIntervalSec =
      int.tryParse(dotenv.env['SONOS_POLL_INTERVAL_SEC'] ?? '');
  final maxAvatarsPerUser =
      int.tryParse(dotenv.env['MAX_AVATARS_PER_USER'] ?? '') ?? 5;
  final spotifyDirectPollIntervalSec =
      int.tryParse(dotenv.env['SPOTIFY_DIRECT_POLL_INTERVAL_SEC'] ?? '') ?? 3;
  final spotifyDirectRetryIntervalSec =
      int.tryParse(dotenv.env['SPOTIFY_DIRECT_RETRY_INTERVAL_SEC'] ?? '') ?? 3;
  final spotifyDirectRetryWindowSec =
      int.tryParse(dotenv.env['SPOTIFY_DIRECT_RETRY_WINDOW_SEC'] ?? '') ?? 10;
  final spotifyDirectCooldownSec =
      int.tryParse(dotenv.env['SPOTIFY_DIRECT_COOLDOWN_SEC'] ?? '') ?? 30;
  final wsForceReconnIdleSec =
      int.tryParse(dotenv.env['WS_FORCE_RECONN_IDLE_SEC'] ?? '') ?? 30;
  final spotifyDirectApiSslVerify =
      (dotenv.env['SPOTIFY_DIRECT_API_SSL_VERIFY'] ?? 'true').toLowerCase() ==
          'true';
  final spotifyDirectApiBaseUrl =
      dotenv.env['SPOTIFY_DIRECT_API_BASE_URL'] ?? 'https://api.spotify.com/v1';
  return EnvConfig(
    apiBaseUrl: api,
    eventsWsUrl: ws,
    flavor: flavor,
    apiSslVerify: apiSslVerify,
    eventsWsSslVerify: wsSslVerify,
    wsRetryIntervalMs: wsRetryIntervalMs,
    wsRetryActiveSeconds: wsRetryActiveSeconds,
    wsRetryCooldownSeconds: wsRetryCooldownSeconds,
    wsRetryMaxTotalSeconds: wsRetryMaxTotalSeconds,
    spotifyPollIntervalSec: spotifyPollIntervalSec,
    sonosPollIntervalSec: sonosPollIntervalSec,
    maxAvatarsPerUser: maxAvatarsPerUser,
    spotifyDirectPollIntervalSec: spotifyDirectPollIntervalSec,
    spotifyDirectRetryIntervalSec: spotifyDirectRetryIntervalSec,
    spotifyDirectRetryWindowSec: spotifyDirectRetryWindowSec,
    spotifyDirectCooldownSec: spotifyDirectCooldownSec,
    wsForceReconnIdleSec: wsForceReconnIdleSec,
    spotifyDirectApiSslVerify: spotifyDirectApiSslVerify,
    spotifyDirectApiBaseUrl: spotifyDirectApiBaseUrl,
  );
});

Future<void> loadEnv() async {
  await dotenv.load(fileName: 'assets/conf/.env');
}
