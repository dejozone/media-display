import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/utils/logging.dart';

final _envLogger = appLogger('EnvConfig');

/// Service types for priority-based service selection
enum ServiceType {
  directSpotify,
  cloudSpotify,
  localSonos,
  nativeLocalSonos;

  static ServiceType? fromString(String value) {
    switch (value.toLowerCase().trim()) {
      case 'direct_spotify':
        return ServiceType.directSpotify;
      case 'cloud_spotify':
        return ServiceType.cloudSpotify;
      case 'local_sonos':
        return ServiceType.localSonos;
      case 'native_local_sonos':
        return ServiceType.nativeLocalSonos;
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
      case ServiceType.nativeLocalSonos:
        return 'native_local_sonos';
    }
  }

  /// Whether this service requires Spotify to be enabled in user settings
  bool get requiresSpotify {
    switch (this) {
      case ServiceType.directSpotify:
      case ServiceType.cloudSpotify:
        return true;
      case ServiceType.localSonos:
      case ServiceType.nativeLocalSonos:
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
      case ServiceType.nativeLocalSonos:
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

  /// Whether this service is the native (on-device) Sonos bridge
  bool get isNativeSonos => this == ServiceType.nativeLocalSonos;

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
      case ServiceType.nativeLocalSonos:
        // Native bridge handles Sonos locally; disable backend polling
        return (spotify: false, sonos: false);
    }
  }
}

/// Platform modes used to select platform-specific priority ordering.
enum ClientPlatformMode {
  web,
  macos,
  windows,
  linux,
  android,
  ios,
  embedded,
  defaultMode;

  String get label {
    switch (this) {
      case ClientPlatformMode.web:
        return 'web';
      case ClientPlatformMode.macos:
        return 'macos';
      case ClientPlatformMode.windows:
        return 'windows';
      case ClientPlatformMode.linux:
        return 'linux';
      case ClientPlatformMode.android:
        return 'android';
      case ClientPlatformMode.ios:
        return 'ios';
      case ClientPlatformMode.embedded:
        return 'embedded';
      case ClientPlatformMode.defaultMode:
        return 'default';
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
    required this.retryTimeSec,
    required this.fallbackTimeThresholdSec,
  });

  final int timeoutSec;
  final bool onError;
  final int errorThreshold;
  final int retryIntervalSec;
  final int retryCooldownSec;

  /// Maximum time a retry/recovery cycle can run before forcing cooldown (0 = infinite)
  final int retryTimeSec;
  final int fallbackTimeThresholdSec;
}

class EnvConfig {
  EnvConfig({
    required this.platformMode,
    required this.apiBaseUrl,
    required this.eventsWsUrl,
    required this.flavor,
    required this.logLevel,
    required this.apiSslVerify,
    required this.eventsWsSslVerify,
    required this.wsRetryIntervalMs,
    required this.wsRetryActiveSec,
    required this.wsRetryCooldownSec,
    required this.wsRetryWindowSec,
    required this.cloudSpotifyPollIntervalSec,
    required this.maxAvatarsPerUser,
    required this.directSpotifyPollIntervalSec,
    required this.directSpotifyTimeoutSec,
    required this.directSpotifyRetryIntervalSec,
    required this.directSpotifyRetryTimeSec,
    required this.directSpotifyRetryCooldownSec,
    required this.wsForceReconnIdleSec,
    required this.directSpotifyApiSslVerify,
    required this.directSpotifyApiBaseUrl,
    this.nativeSonosPollIntervalSec,
    required this.priorityOrderOfServices,
    required this.spotifyDirectFallback,
    required this.cloudSpotifyFallback,
    required this.localSonosFallback,
    required this.nativeLocalSonosFallback,
    required this.localSonosPausedWaitSec,
    required this.localSonosStoppedWaitSec,
    required this.localSonosIdleWaitSec,
    required this.nativeLocalSonosPausedWaitSec,
    required this.nativeLocalSonosStoppedWaitSec,
    required this.nativeLocalSonosIdleWaitSec,
    required this.spotifyPausedWaitSec,
    required this.enableServiceCycling,
    required this.serviceCycleResetSec,
    required this.serviceTransitionGraceSec,
    required this.serviceIdleCycleResetSec,
    required this.serviceIdleTimeSec,
    this.sonosPollIntervalSec,
  });

  final String apiBaseUrl;
  final ClientPlatformMode platformMode;
  final String eventsWsUrl;
  final String flavor;
  final String logLevel;
  final bool apiSslVerify;
  final bool eventsWsSslVerify;
  final int wsRetryIntervalMs;
  final int wsRetryActiveSec;
  final int wsRetryCooldownSec;
  final int wsRetryWindowSec;
  final int directSpotifyTimeoutSec;
  final int cloudSpotifyPollIntervalSec;
  final int? sonosPollIntervalSec;
  final int? nativeSonosPollIntervalSec;
  final int maxAvatarsPerUser;
  final int directSpotifyPollIntervalSec;
  final int directSpotifyRetryIntervalSec;
  final int directSpotifyRetryTimeSec;
  final int directSpotifyRetryCooldownSec;
  final int wsForceReconnIdleSec;
  final bool directSpotifyApiSslVerify;
  final String directSpotifyApiBaseUrl;

  // Service priority configuration
  final List<ServiceType> priorityOrderOfServices;
  final ServiceFallbackConfig spotifyDirectFallback;
  final ServiceFallbackConfig cloudSpotifyFallback;
  final ServiceFallbackConfig localSonosFallback;
  final ServiceFallbackConfig nativeLocalSonosFallback;
  final int localSonosPausedWaitSec;
  final int localSonosStoppedWaitSec;
  final int localSonosIdleWaitSec;
  final int nativeLocalSonosPausedWaitSec;
  final int nativeLocalSonosStoppedWaitSec;
  final int nativeLocalSonosIdleWaitSec;
  final int spotifyPausedWaitSec;
  final bool enableServiceCycling;
  final int serviceCycleResetSec;
  final int serviceTransitionGraceSec;
  final int serviceIdleCycleResetSec;
  final int serviceIdleTimeSec;

  /// Get the fallback config for a specific service type
  ServiceFallbackConfig getFallbackConfig(ServiceType service) {
    switch (service) {
      case ServiceType.directSpotify:
        return spotifyDirectFallback;
      case ServiceType.cloudSpotify:
        return cloudSpotifyFallback;
      case ServiceType.localSonos:
        return localSonosFallback;
      case ServiceType.nativeLocalSonos:
        return nativeLocalSonosFallback;
    }
  }
}

ClientPlatformMode _detectPlatformMode() {
  final override = dotenv.env['PLATFORM_MODE']?.toLowerCase().trim();
  switch (override) {
    case 'web':
      return ClientPlatformMode.web;
    case 'macos':
      return ClientPlatformMode.macos;
    case 'windows':
      return ClientPlatformMode.windows;
    case 'linux':
      return ClientPlatformMode.linux;
    case 'android':
      return ClientPlatformMode.android;
    case 'ios':
      return ClientPlatformMode.ios;
    case 'embedded':
      return ClientPlatformMode.embedded;
  }

  if (kIsWeb) return ClientPlatformMode.web;

  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
      return ClientPlatformMode.macos;
    case TargetPlatform.windows:
      return ClientPlatformMode.windows;
    case TargetPlatform.linux:
      return ClientPlatformMode.linux;
    case TargetPlatform.android:
      return ClientPlatformMode.android;
    case TargetPlatform.iOS:
      return ClientPlatformMode.ios;
    case TargetPlatform.fuchsia:
      // Treat fuchsia as embedded by default
      return ClientPlatformMode.embedded;
  }
}

List<ServiceType> _allowedServicesForMode(ClientPlatformMode mode) {
  switch (mode) {
    case ClientPlatformMode.web:
      return const [
        ServiceType.localSonos,
        ServiceType.directSpotify,
        ServiceType.cloudSpotify,
      ];
    case ClientPlatformMode.android:
    case ClientPlatformMode.ios:
      return const [
        ServiceType.nativeLocalSonos,
        ServiceType.directSpotify,
        ServiceType.cloudSpotify,
      ];
    case ClientPlatformMode.macos:
    case ClientPlatformMode.windows:
    case ClientPlatformMode.linux:
    case ClientPlatformMode.embedded:
      return const [
        ServiceType.nativeLocalSonos,
        ServiceType.localSonos,
        ServiceType.directSpotify,
        ServiceType.cloudSpotify,
      ];
    case ClientPlatformMode.defaultMode:
      return const [
        ServiceType.directSpotify,
        ServiceType.cloudSpotify,
      ];
  }
}

String _priorityKeyForMode(ClientPlatformMode mode) {
  switch (mode) {
    case ClientPlatformMode.web:
      return 'WEB_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.macos:
      return 'MACOS_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.windows:
      return 'WINDOWS_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.linux:
      return 'LINUX_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.android:
      return 'ANDROID_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.ios:
      return 'IOS_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.embedded:
      return 'EMBEDDED_PRIORITY_ORDER_OF_SERVICES';
    case ClientPlatformMode.defaultMode:
      return 'DEF_PRIORITY_ORDER_OF_SERVICES';
  }
}

List<ServiceType> _parsePriorityOrder(
  String? raw,
  List<ServiceType> allowed,
) {
  final result = <ServiceType>[];

  if (raw != null && raw.trim().isNotEmpty) {
    for (final part in raw.split(',')) {
      final service = ServiceType.fromString(part);
      if (service != null && allowed.contains(service)) {
        if (!result.contains(service)) {
          result.add(service);
        }
      }
    }
  }

  // If nothing was parsed (empty or all invalid), fall back to allowed list
  if (result.isEmpty) {
    return List<ServiceType>.from(allowed);
  }

  return result;
}

final envConfigProvider = Provider<EnvConfig>((ref) {
  final api = dotenv.env['API_BASE_URL'] ?? 'http://localhost:5001';
  final ws = dotenv.env['WS_BASE_URL'] ?? 'ws://localhost:5002/events/media';
  final flavor = dotenv.env['FLAVOR'] ?? 'dev';
  final logLevel = (dotenv.env['LOG_LEVEL'] ?? 'INFO').toUpperCase();
  final apiSslVerify =
      (dotenv.env['API_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsSslVerify =
      (dotenv.env['WS_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsRetryIntervalMs =
      int.tryParse(dotenv.env['WS_RETRY_INTERVAL_MS'] ?? '') ?? 3000;
  final wsRetryActiveSec =
      int.tryParse(dotenv.env['WS_RETRY_ACTIVE_SEC'] ?? '') ?? 60;
  final wsRetryCooldownSec =
      int.tryParse(dotenv.env['WS_RETRY_COOLDOWN_SEC'] ?? '') ?? 60;
  int _parseRetryTimeSec(String key,
      {List<String> legacyKeys = const [], int defaultValue = 0}) {
    final raw = dotenv.env[key]?.trim();
    final value = int.tryParse(raw ?? '');
    if (value != null) return value;

    for (final legacyKey in legacyKeys) {
      final legacyRaw = dotenv.env[legacyKey]?.trim();
      final legacyValue = int.tryParse(legacyRaw ?? '');
      if (legacyValue != null) return legacyValue;
    }

    // 0 or negative means infinite; empty/null should default to infinite (0)
    return defaultValue;
  }

  final wsRetryWindowSec = _parseRetryTimeSec('WS_RETRY_WINDOW_SEC');
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
  final directSpotifyRetryTimeSec = _parseRetryTimeSec(
    'DIRECT_SPOTIFY_RETRY_TIME_SEC',
    legacyKeys: [
      'DIRECT_SPOTIFY_RETRY_WINDOW_SEC',
      'DIRECT_SPOTIFY_RETRY_MAX_WINDOW_SEC',
    ],
  );
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
  final nativeSonosPollIntervalSecRaw =
      int.tryParse(dotenv.env['NATIVE_LOCAL_SONOS_POLL_INTERVAL_SEC'] ?? '');
  final nativeSonosPollIntervalSec = (nativeSonosPollIntervalSecRaw == null ||
          nativeSonosPollIntervalSecRaw <= 0)
      ? null
      : nativeSonosPollIntervalSecRaw;

  // Parse service priority order based on platform mode
  final platformMode = _detectPlatformMode();
  final priorityEnvKey = _priorityKeyForMode(platformMode);

  // Parse primary priority list; if empty/invalid, fall back to DEF_PRIORITY_ORDER_OF_SERVICES.
  final allowedServices = _allowedServicesForMode(platformMode);
  final primaryPriorityString = dotenv.env[priorityEnvKey];
  final defaultPriorityString = dotenv.env['DEF_PRIORITY_ORDER_OF_SERVICES'];

  var priorityOrderOfServices =
      _parsePriorityOrder(primaryPriorityString, allowedServices);

  if (priorityOrderOfServices.isEmpty && defaultPriorityString != null) {
    priorityOrderOfServices =
        _parsePriorityOrder(defaultPriorityString, allowedServices);
  }

  // As a last resort, keep the allowed order to avoid an empty list.
  if (priorityOrderOfServices.isEmpty) {
    priorityOrderOfServices = List<ServiceType>.from(allowedServices);
  }

  _envLogger.info(
    'Priority mode=${platformMode.label} key=$priorityEnvKey order='
    '${priorityOrderOfServices.map((s) => s.toConfigString()).join(',')}',
  );

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
    retryTimeSec: directSpotifyRetryTimeSec,
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
    retryTimeSec: _parseRetryTimeSec(
      'CLOUD_SPOTIFY_RETRY_TIME_SEC',
      legacyKeys: [
        'CLOUD_SPOTIFY_RETRY_WINDOW_SEC',
        'CLOUD_SPOTIFY_RETRY_MAX_WINDOW_SEC',
      ],
    ),
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
    retryTimeSec: _parseRetryTimeSec(
      'LOCAL_SONOS_RETRY_TIME_SEC',
      legacyKeys: [
        'LOCAL_SONOS_RETRY_WINDOW_SEC',
        'LOCAL_SONOS_RETRY_MAX_WINDOW_SEC',
      ],
    ),
  );

  // Parse Native Local Sonos fallback config (on-device bridge)
  final nativeLocalSonosFallback = ServiceFallbackConfig(
    timeoutSec: int.tryParse(
            dotenv.env['NATIVE_LOCAL_SONOS_FALLBACK_TIMEOUT_SEC'] ?? '') ??
        0, // 0 = disabled (event-driven)
    onError: (dotenv.env['NATIVE_LOCAL_SONOS_FALLBACK_ON_ERROR'] ?? 'true')
            .toLowerCase() ==
        'true',
    errorThreshold: int.tryParse(
            dotenv.env['NATIVE_LOCAL_SONOS_FALLBACK_ERROR_THRESHOLD'] ?? '') ??
        3,
    fallbackTimeThresholdSec: int.tryParse(
            dotenv.env['NATIVE_LOCAL_SONOS_FALLBACK_TIME_THRESHOLD_SEC'] ??
                '') ??
        10,
    retryIntervalSec: int.tryParse(
            dotenv.env['NATIVE_LOCAL_SONOS_RETRY_INTERVAL_SEC'] ?? '') ??
        10,
    retryCooldownSec: int.tryParse(
            dotenv.env['NATIVE_LOCAL_SONOS_RETRY_COOLDOWN_SEC'] ?? '') ??
        30,
    retryTimeSec: _parseRetryTimeSec(
      'NATIVE_LOCAL_SONOS_RETRY_TIME_SEC',
      legacyKeys: [
        'NATIVE_LOCAL_SONOS_RETRY_WINDOW_SEC',
        'NATIVE_LOCAL_SONOS_RETRY_MAX_WINDOW_SEC',
      ],
    ),
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

  // Native local Sonos wait times (defaults to match local sonos if unset)
  final nativeLocalSonosPausedWaitSec =
      int.tryParse(dotenv.env['NATIVE_LOCAL_SONOS_PAUSED_WAIT_SEC'] ?? '') ??
          localSonosPausedWaitSec;
  final nativeLocalSonosStoppedWaitSec =
      int.tryParse(dotenv.env['NATIVE_LOCAL_SONOS_STOPPED_WAIT_SEC'] ?? '') ??
          localSonosStoppedWaitSec;
  final nativeLocalSonosIdleWaitSec =
      int.tryParse(dotenv.env['NATIVE_LOCAL_SONOS_IDLE_WAIT_SEC'] ?? '') ??
          localSonosIdleWaitSec;

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

  // Idle reset safeguards
  final serviceIdleCycleResetSec =
      int.tryParse(dotenv.env['SERVICE_IDLE_CYCLE_RESET_SEC'] ?? '') ?? 0;
  final serviceIdleTimeSec =
      int.tryParse(dotenv.env['SERVICE_IDLE_TIME_SEC'] ?? '') ?? 0;

  return EnvConfig(
    platformMode: platformMode,
    apiBaseUrl: api,
    eventsWsUrl: ws,
    flavor: flavor,
    logLevel: logLevel,
    apiSslVerify: apiSslVerify,
    eventsWsSslVerify: wsSslVerify,
    wsRetryIntervalMs: wsRetryIntervalMs,
    wsRetryActiveSec: wsRetryActiveSec,
    wsRetryCooldownSec: wsRetryCooldownSec,
    wsRetryWindowSec: wsRetryWindowSec,
    directSpotifyTimeoutSec: directSpotifyTimeoutSec,
    cloudSpotifyPollIntervalSec: cloudSpotifyPollIntervalSec,
    sonosPollIntervalSec: sonosPollIntervalSec,
    maxAvatarsPerUser: maxAvatarsPerUser,
    directSpotifyPollIntervalSec: directSpotifyPollIntervalSec,
    directSpotifyRetryIntervalSec: directSpotifyRetryIntervalSec,
    directSpotifyRetryTimeSec: directSpotifyRetryTimeSec,
    directSpotifyRetryCooldownSec: directSpotifyRetryCooldownSec,
    wsForceReconnIdleSec: wsForceReconnIdleSec,
    directSpotifyApiSslVerify: directSpotifyApiSslVerify,
    directSpotifyApiBaseUrl: directSpotifyApiBaseUrl,
    nativeSonosPollIntervalSec: nativeSonosPollIntervalSec,
    priorityOrderOfServices: priorityOrderOfServices,
    spotifyDirectFallback: spotifyDirectFallback,
    cloudSpotifyFallback: cloudSpotifyFallback,
    localSonosFallback: localSonosFallback,
    nativeLocalSonosFallback: nativeLocalSonosFallback,
    localSonosPausedWaitSec: localSonosPausedWaitSec,
    localSonosStoppedWaitSec: localSonosStoppedWaitSec,
    localSonosIdleWaitSec: localSonosIdleWaitSec,
    nativeLocalSonosPausedWaitSec: nativeLocalSonosPausedWaitSec,
    nativeLocalSonosStoppedWaitSec: nativeLocalSonosStoppedWaitSec,
    nativeLocalSonosIdleWaitSec: nativeLocalSonosIdleWaitSec,
    spotifyPausedWaitSec: spotifyPausedWaitSec,
    enableServiceCycling: enableServiceCycling,
    serviceCycleResetSec: serviceCycleResetSec,
    serviceTransitionGraceSec: serviceTransitionGraceSec,
    serviceIdleCycleResetSec: serviceIdleCycleResetSec,
    serviceIdleTimeSec: serviceIdleTimeSec,
  );
});

Future<void> loadEnv() async {
  await dotenv.load(fileName: 'conf/.env');
}
