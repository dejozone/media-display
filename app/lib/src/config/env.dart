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
    required this.retryWindowSec,
    required this.fallbackTimeThresholdSec,
  });

  final int timeoutSec;
  final bool onError;
  final int errorThreshold;
  final int retryIntervalSec;
  final int retryCooldownSec;
  final int retryWindowSec;
  final int fallbackTimeThresholdSec;
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
    required this.cloudSpotifyPollIntervalSec,
    required this.maxAvatarsPerUser,
    required this.directSpotifyPollIntervalSec,
    required this.directSpotifyTimeoutSec,
    required this.directSpotifyRetryIntervalSec,
    required this.directSpotifyRetryWindowSec,
    required this.directSpotifyRetryCooldownSec,
    required this.wsForceReconnIdleSec,
    required this.directSpotifyApiSslVerify,
    required this.directSpotifyApiBaseUrl,
    required this.priorityOrderOfServices,
    required this.spotifyDirectFallback,
    required this.cloudSpotifyFallback,
    required this.localSonosFallback,
    required this.localSonosPausedWaitSec,
    required this.localSonosStoppedWaitSec,
    required this.localSonosIdleWaitSec,
    required this.spotifyPausedWaitSec,
    required this.enableServiceCycling,
    required this.serviceCycleResetSec,
    required this.serviceTransitionGraceSec,
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
  final int directSpotifyTimeoutSec;
  final int cloudSpotifyPollIntervalSec;
  final int? sonosPollIntervalSec;
  final int maxAvatarsPerUser;
  final int directSpotifyPollIntervalSec;
  final int directSpotifyRetryIntervalSec;
  final int directSpotifyRetryWindowSec;
  final int directSpotifyRetryCooldownSec;
  final int wsForceReconnIdleSec;
  final bool directSpotifyApiSslVerify;
  final String directSpotifyApiBaseUrl;

  // Service priority configuration
  final List<ServiceType> priorityOrderOfServices;
  final ServiceFallbackConfig spotifyDirectFallback;
  final ServiceFallbackConfig cloudSpotifyFallback;
  final ServiceFallbackConfig localSonosFallback;
  final int localSonosPausedWaitSec;
  final int localSonosStoppedWaitSec;
  final int localSonosIdleWaitSec;
  final int spotifyPausedWaitSec;
  final bool enableServiceCycling;
  final int serviceCycleResetSec;
  final int serviceTransitionGraceSec;

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
  final ws = dotenv.env['WS_BASE_URL'] ?? 'ws://localhost:5002/events/media';
  final flavor = dotenv.env['FLAVOR'] ?? 'dev';
  final apiSslVerify =
      (dotenv.env['API_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsSslVerify =
      (dotenv.env['WS_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsRetryIntervalMs =
      int.tryParse(dotenv.env['WS_RETRY_INTERVAL_MS'] ?? '') ?? 3000;
  final wsRetryActiveSeconds =
      int.tryParse(dotenv.env['WS_RETRY_ACTIVE_SECONDS'] ?? '') ?? 60;
  final wsRetryCooldownSeconds =
      int.tryParse(dotenv.env['WS_RETRY_COOLDOWN_SECONDS'] ?? '') ?? 60;
  final wsRetryMaxTotalSeconds =
      int.tryParse(dotenv.env['WS_RETRY_MAX_TOTAL_SECONDS'] ?? '') ?? 1800;
  final directSpotifyTimeoutSec =
      int.tryParse(dotenv.env['DIRECT_SPOTIFY_TIMEOUT_SEC'] ?? '') ?? 3;
  final cloudSpotifyPollIntervalSec =
      int.tryParse(dotenv.env['CLOUD_SPOTIFY_POLL_INTERVAL_SEC'] ?? '') ?? 3;
  // Sonos poll interval: null or 0 means let the server decide
  final sonosPollIntervalSecRaw =
      int.tryParse(dotenv.env['LOCAL_SONOS_POLL_INTERVAL_SEC'] ?? '');
  final sonosPollIntervalSec =
      (sonosPollIntervalSecRaw == null || sonosPollIntervalSecRaw <= 0)
          ? null
          : sonosPollIntervalSecRaw;
  final maxAvatarsPerUser =
      int.tryParse(dotenv.env['MAX_AVATARS_PER_USER'] ?? '') ?? 5;
  final directSpotifyPollIntervalSec =
      int.tryParse(dotenv.env['DIRECT_SPOTIFY_POLL_INTERVAL_SEC'] ?? '') ?? 3;
  final directSpotifyRetryIntervalSec =
      int.tryParse(dotenv.env['DIRECT_SPOTIFY_RETRY_INTERVAL_SEC'] ?? '') ?? 3;
  final directSpotifyRetryWindowSec =
      int.tryParse(dotenv.env['DIRECT_SPOTIFY_RETRY_WINDOW_SEC'] ?? '') ?? 0;
  // Prefer new retry cooldown key; fall back to legacy DIRECT_SPOTIFY_RETRY_COOLDOWN_SEC
  final directSpotifyRetryCooldownSec =
      int.tryParse(dotenv.env['DIRECT_SPOTIFY_RETRY_COOLDOWN_SEC'] ?? '') ?? 30;
  final wsForceReconnIdleSec =
      int.tryParse(dotenv.env['WS_FORCE_RECONN_IDLE_SEC'] ?? '') ?? 30;
  final directSpotifyApiSslVerify =
      (dotenv.env['DIRECT_SPOTIFY_API_SSL_VERIFY'] ?? 'true').toLowerCase() ==
          'true';
  final directSpotifyApiBaseUrl =
      dotenv.env['DIRECT_SPOTIFY_API_BASE_URL'] ?? 'https://api.spotify.com/v1';

  // Parse service priority order
  // Default: Sonos is primary when both are enabled, then direct Spotify, then cloud Spotify
  final priorityOrderString = dotenv.env['PRIORITY_ORDER_OF_SERVICES'] ??
      'local_sonos,direct_spotify,cloud_spotify';

  // Parse, deduplicate, and append any missing service types to keep a stable
  // total ordering even if the env omits a value. This avoids hash-set
  // reordering when logging while preserving the user-specified precedence.
  final parsedPriorityOrder = priorityOrderString
      .split(',')
      .map((s) => ServiceType.fromString(s))
      .whereType<ServiceType>()
      .toList();

  final seen = <ServiceType>{};
  final priorityOrderOfServices = <ServiceType>[];

  for (final service in parsedPriorityOrder) {
    if (seen.add(service)) {
      priorityOrderOfServices.add(service);
    }
  }

  // Append any missing services in a deterministic order so every service has
  // a position even if not explicitly listed in the env value.
  for (final service in ServiceType.values) {
    if (seen.add(service)) {
      priorityOrderOfServices.add(service);
    }
  }

  // Ensure we have at least one service (defensive, should never be empty here)
  if (priorityOrderOfServices.isEmpty) {
    priorityOrderOfServices.addAll([
      ServiceType.localSonos,
      ServiceType.directSpotify,
      ServiceType.cloudSpotify,
    ]);
  }

  // Parse Spotify Direct fallback config
  final spotifyDirectFallback = ServiceFallbackConfig(
    timeoutSec:
        int.tryParse(dotenv.env['DIRECT_SPOTIFY_FALLBACK_TIMEOUT_SEC'] ?? '') ??
            5,
    onError: (dotenv.env['DIRECT_SPOTIFY_FALLBACK_ON_ERROR'] ?? 'true')
            .toLowerCase() ==
        'true',
    errorThreshold: int.tryParse(
            dotenv.env['DIRECT_SPOTIFY_FALLBACK_ERROR_THRESHOLD'] ?? '') ??
        3,
    fallbackTimeThresholdSec: int.tryParse(
            dotenv.env['DIRECT_SPOTIFY_FALLBACK_TIME_THRESHOLD_SEC'] ?? '') ??
        10,
    retryIntervalSec: directSpotifyRetryIntervalSec,
    retryCooldownSec: directSpotifyRetryCooldownSec,
    retryWindowSec: directSpotifyRetryWindowSec,
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
    fallbackTimeThresholdSec: int.tryParse(
            dotenv.env['CLOUD_SPOTIFY_FALLBACK_TIME_THRESHOLD_SEC'] ?? '') ??
        10,
    retryIntervalSec:
        int.tryParse(dotenv.env['CLOUD_SPOTIFY_RETRY_INTERVAL_SEC'] ?? '') ??
            10,
    retryCooldownSec:
        int.tryParse(dotenv.env['CLOUD_SPOTIFY_RETRY_COOLDOWN_SEC'] ?? '') ??
            30,
    retryWindowSec: int.tryParse(
            dotenv.env['CLOUD_SPOTIFY_RETRY_WINDOW_SEC'] ?? '') ??
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
    fallbackTimeThresholdSec: int.tryParse(
            dotenv.env['LOCAL_SONOS_FALLBACK_TIME_THRESHOLD_SEC'] ?? '') ??
        10,
    retryIntervalSec:
        int.tryParse(dotenv.env['LOCAL_SONOS_RETRY_INTERVAL_SEC'] ?? '') ?? 10,
    retryCooldownSec:
        int.tryParse(dotenv.env['LOCAL_SONOS_RETRY_COOLDOWN_SEC'] ?? '') ?? 30,
    retryWindowSec: int.tryParse(
            dotenv.env['LOCAL_SONOS_RETRY_WINDOW_SEC'] ?? '') ??
        int.tryParse(dotenv.env['LOCAL_SONOS_RETRY_MAX_WINDOW_SEC'] ?? '') ??
        300,
  );

  // Parse Local Sonos auto-switch settings (state-based wait times)
  // 0 = disabled (don't cycle for that state)
  final localSonosPausedWaitSec =
      int.tryParse(dotenv.env['LOCAL_SONOS_PAUSED_WAIT_SEC'] ?? '') ??
          0; // Default: don't cycle on pause
  final localSonosStoppedWaitSec =
      int.tryParse(dotenv.env['LOCAL_SONOS_STOPPED_WAIT_SEC'] ?? '') ??
          30; // Wait 30s after stopped
  final localSonosIdleWaitSec =
      int.tryParse(dotenv.env['LOCAL_SONOS_IDLE_WAIT_SEC'] ?? '') ??
          3; // Quick cycle on idle/no media

  // Parse Spotify paused wait time
  final spotifyPausedWaitSec =
      int.tryParse(dotenv.env['SPOTIFY_PAUSED_WAIT_SEC'] ?? '') ?? 5;

  // Parse service cycling settings
  final enableServiceCycling =
      (dotenv.env['ENABLE_SERVICE_CYCLING'] ?? 'true').toLowerCase() == 'true';
  final serviceCycleResetSec =
      int.tryParse(dotenv.env['SERVICE_CYCLE_RESET_SEC'] ?? '') ?? 30;

  // Parse global service settings
  final serviceTransitionGraceSec =
      int.tryParse(dotenv.env['SERVICE_TRANSITION_GRACE_SEC'] ?? '') ?? 2;

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
    directSpotifyTimeoutSec: directSpotifyTimeoutSec,
    cloudSpotifyPollIntervalSec: cloudSpotifyPollIntervalSec,
    sonosPollIntervalSec: sonosPollIntervalSec,
    maxAvatarsPerUser: maxAvatarsPerUser,
    directSpotifyPollIntervalSec: directSpotifyPollIntervalSec,
    directSpotifyRetryIntervalSec: directSpotifyRetryIntervalSec,
    directSpotifyRetryWindowSec: directSpotifyRetryWindowSec,
    directSpotifyRetryCooldownSec: directSpotifyRetryCooldownSec,
    wsForceReconnIdleSec: wsForceReconnIdleSec,
    directSpotifyApiSslVerify: directSpotifyApiSslVerify,
    directSpotifyApiBaseUrl: directSpotifyApiBaseUrl,
    priorityOrderOfServices: priorityOrderOfServices,
    spotifyDirectFallback: spotifyDirectFallback,
    cloudSpotifyFallback: cloudSpotifyFallback,
    localSonosFallback: localSonosFallback,
    localSonosPausedWaitSec: localSonosPausedWaitSec,
    localSonosStoppedWaitSec: localSonosStoppedWaitSec,
    localSonosIdleWaitSec: localSonosIdleWaitSec,
    spotifyPausedWaitSec: spotifyPausedWaitSec,
    enableServiceCycling: enableServiceCycling,
    serviceCycleResetSec: serviceCycleResetSec,
    serviceTransitionGraceSec: serviceTransitionGraceSec,
  );
});

Future<void> loadEnv() async {
  await dotenv.load(fileName: 'conf/.env');
}
