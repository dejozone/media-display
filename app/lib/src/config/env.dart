import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Service types for priority-based service selection
enum ServiceType {
  directSpotify,
  cloudSpotify,
  localSonos;

  static ServiceType? fromString(String value) {
    switch (value.toLowerCase().trim()) {
      case 'direct_spotify':
        return ServiceType.directSpotify;
      case 'cloud_spotify':
        return ServiceType.cloudSpotify;
      case 'local_sonos':
        return ServiceType.localSonos;
      default:
        return null;
    }
  }

  String toConfigString() {
    switch (this) {
      case ServiceType.directSpotify:
        return 'direct_spotify';
      case ServiceType.cloudSpotify:
        return 'cloud_spotify';
      case ServiceType.localSonos:
        return 'local_sonos';
    }
  }

  /// Whether this service requires Spotify to be enabled in user settings
  bool get requiresSpotify {
    switch (this) {
      case ServiceType.directSpotify:
      case ServiceType.cloudSpotify:
        return true;
      case ServiceType.localSonos:
        return false;
    }
  }

  /// Whether this service requires Sonos to be enabled in user settings
  bool get requiresSonos {
    switch (this) {
      case ServiceType.directSpotify:
      case ServiceType.cloudSpotify:
        return false;
      case ServiceType.localSonos:
        return true;
    }
  }

  /// Whether this service uses the client to poll directly (vs backend)
  bool get isDirectPolling {
    return this == ServiceType.directSpotify;
  }

  /// Whether this service uses WebSocket/cloud backend
  bool get isCloudService {
    return this == ServiceType.cloudSpotify || this == ServiceType.localSonos;
  }

  /// Get WebSocket config payload for this service
  /// Returns {spotify: bool, sonos: bool} for backend polling config
  ({bool spotify, bool sonos}) get webSocketConfig {
    switch (this) {
      case ServiceType.directSpotify:
        // Client polls directly, backend doesn't need to poll
        return (spotify: false, sonos: false);
      case ServiceType.cloudSpotify:
        // Backend polls Spotify
        return (spotify: true, sonos: false);
      case ServiceType.localSonos:
        // Backend polls Sonos
        return (spotify: false, sonos: true);
    }
  }
}

/// Fallback configuration for a service
class ServiceFallbackConfig {
  const ServiceFallbackConfig({
    required this.timeoutSec,
    required this.onError,
    required this.errorThreshold,
    required this.retryIntervalSec,
    required this.retryCooldownSec,
    required this.retryMaxWindowSec,
  });

  final int timeoutSec;
  final bool onError;
  final int errorThreshold;
  final int retryIntervalSec;
  final int retryCooldownSec;
  final int retryMaxWindowSec;
}

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
    required this.priorityOrderOfServices,
    required this.spotifyDirectFallback,
    required this.cloudSpotifyFallback,
    required this.localSonosFallback,
    required this.serviceTransitionGraceSec,
    required this.tokenWaitTimeoutSec,
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

  // Service priority configuration
  final List<ServiceType> priorityOrderOfServices;
  final ServiceFallbackConfig spotifyDirectFallback;
  final ServiceFallbackConfig cloudSpotifyFallback;
  final ServiceFallbackConfig localSonosFallback;
  final int serviceTransitionGraceSec;
  final int tokenWaitTimeoutSec;

  /// Get the fallback config for a specific service type
  ServiceFallbackConfig getFallbackConfig(ServiceType service) {
    switch (service) {
      case ServiceType.directSpotify:
        return spotifyDirectFallback;
      case ServiceType.cloudSpotify:
        return cloudSpotifyFallback;
      case ServiceType.localSonos:
        return localSonosFallback;
    }
  }
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
  // Sonos poll interval: null or 0 means let the server decide
  final sonosPollIntervalSecRaw =
      int.tryParse(dotenv.env['SONOS_POLL_INTERVAL_SEC'] ?? '');
  final sonosPollIntervalSec =
      (sonosPollIntervalSecRaw == null || sonosPollIntervalSecRaw <= 0)
          ? null
          : sonosPollIntervalSecRaw;
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

  // Parse service priority order
  final priorityOrderString = dotenv.env['PRIORITY_ORDER_OF_SERVICES'] ??
      'direct_spotify,cloud_spotify,local_sonos';
  final priorityOrderOfServices = priorityOrderString
      .split(',')
      .map((s) => ServiceType.fromString(s))
      .whereType<ServiceType>()
      .toList();
  // Ensure we have at least one service
  if (priorityOrderOfServices.isEmpty) {
    priorityOrderOfServices.addAll([
      ServiceType.directSpotify,
      ServiceType.cloudSpotify,
      ServiceType.localSonos
    ]);
  }

  // Parse Spotify Direct fallback config
  final spotifyDirectFallback = ServiceFallbackConfig(
    timeoutSec:
        int.tryParse(dotenv.env['SPOTIFY_DIRECT_FALLBACK_TIMEOUT_SEC'] ?? '') ??
            5,
    onError: (dotenv.env['SPOTIFY_DIRECT_FALLBACK_ON_ERROR'] ?? 'true')
            .toLowerCase() ==
        'true',
    errorThreshold: int.tryParse(
            dotenv.env['SPOTIFY_DIRECT_FALLBACK_ERROR_THRESHOLD'] ?? '') ??
        3,
    retryIntervalSec:
        int.tryParse(dotenv.env['SPOTIFY_DIRECT_RETRY_INTERVAL_SEC'] ?? '') ??
            10,
    retryCooldownSec:
        int.tryParse(dotenv.env['SPOTIFY_DIRECT_RETRY_COOLDOWN_SEC'] ?? '') ??
            30,
    retryMaxWindowSec:
        int.tryParse(dotenv.env['SPOTIFY_DIRECT_RETRY_MAX_WINDOW_SEC'] ?? '') ??
            300,
  );

  // Parse Cloud Spotify fallback config
  final cloudSpotifyFallback = ServiceFallbackConfig(
    timeoutSec:
        int.tryParse(dotenv.env['CLOUD_SPOTIFY_FALLBACK_TIMEOUT_SEC'] ?? '') ??
            5,
    onError: (dotenv.env['CLOUD_SPOTIFY_FALLBACK_ON_ERROR'] ?? 'true')
            .toLowerCase() ==
        'true',
    errorThreshold: int.tryParse(
            dotenv.env['CLOUD_SPOTIFY_FALLBACK_ERROR_THRESHOLD'] ?? '') ??
        3,
    retryIntervalSec:
        int.tryParse(dotenv.env['CLOUD_SPOTIFY_RETRY_INTERVAL_SEC'] ?? '') ??
            10,
    retryCooldownSec:
        int.tryParse(dotenv.env['CLOUD_SPOTIFY_RETRY_COOLDOWN_SEC'] ?? '') ??
            30,
    retryMaxWindowSec:
        int.tryParse(dotenv.env['CLOUD_SPOTIFY_RETRY_MAX_WINDOW_SEC'] ?? '') ??
            300,
  );

  // Parse Local Sonos fallback config
  // NOTE: Sonos is event-driven (only emits on state change), so timeout is disabled by default (0)
  // Fallback for Sonos relies on WebSocket connection state, not data timeout
  final localSonosFallback = ServiceFallbackConfig(
    timeoutSec:
        int.tryParse(dotenv.env['LOCAL_SONOS_FALLBACK_TIMEOUT_SEC'] ?? '') ??
            0, // 0 = disabled (event-driven)
    onError:
        (dotenv.env['LOCAL_SONOS_FALLBACK_ON_ERROR'] ?? 'true').toLowerCase() ==
            'true',
    errorThreshold: int.tryParse(
            dotenv.env['LOCAL_SONOS_FALLBACK_ERROR_THRESHOLD'] ?? '') ??
        3,
    retryIntervalSec:
        int.tryParse(dotenv.env['LOCAL_SONOS_RETRY_INTERVAL_SEC'] ?? '') ?? 10,
    retryCooldownSec:
        int.tryParse(dotenv.env['LOCAL_SONOS_RETRY_COOLDOWN_SEC'] ?? '') ?? 30,
    retryMaxWindowSec:
        int.tryParse(dotenv.env['LOCAL_SONOS_RETRY_MAX_WINDOW_SEC'] ?? '') ??
            300,
  );

  // Parse global service settings
  final serviceTransitionGraceSec =
      int.tryParse(dotenv.env['SERVICE_TRANSITION_GRACE_SEC'] ?? '') ?? 2;
  final tokenWaitTimeoutSec =
      int.tryParse(dotenv.env['TOKEN_WAIT_TIMEOUT_SEC'] ?? '') ?? 10;

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
    priorityOrderOfServices: priorityOrderOfServices,
    spotifyDirectFallback: spotifyDirectFallback,
    cloudSpotifyFallback: cloudSpotifyFallback,
    localSonosFallback: localSonosFallback,
    serviceTransitionGraceSec: serviceTransitionGraceSec,
    tokenWaitTimeoutSec: tokenWaitTimeoutSec,
  );
});

Future<void> loadEnv() async {
  await dotenv.load(fileName: 'conf/.env');
}
