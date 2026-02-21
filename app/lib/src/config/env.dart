import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/utils/logging.dart';

final _envLogger = appLogger('EnvConfig');

// Parsed configuration from conf/.env, grouped by section name.
Map<String, Map<String, String>> _envSections = {};

Map<String, Map<String, String>> _parseEnvWithSections(String content) {
  final sections = <String, Map<String, String>>{};
  String current = '';

  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1).trim();
      sections.putIfAbsent(current, () => <String, String>{});
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();

    final isQuoted = (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"));
    if (!isQuoted) {
      final inlineComment = RegExp(r'\s+#').firstMatch(value);
      if (inlineComment != null) {
        value = value.substring(0, inlineComment.start).trimRight();
      }
    }

    sections.putIfAbsent(current, () => <String, String>{});
    sections[current]![key] = value;
  }

  return sections;
}

String? _getEnv(String section, String key) {
  return _envSections[section]?[key];
}

String? getEnvValue(String section, String key) => _getEnv(section, key);

int _parseInt(String? raw, {int fallback = 0}) {
  final v = int.tryParse(raw ?? '');
  return v ?? fallback;
}

bool _parseBool(String? raw, {bool fallback = true}) {
  if (raw == null || raw.isEmpty) return fallback;
  final lowered = raw.toLowerCase();
  if (lowered == 'true') return true;
  if (lowered == 'false') return false;
  return fallback;
}

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
    required this.enableHomeTrackProgress,
    this.nativeLocalSonosTrackProgressPollIntervalSec,
    this.nativeSonosPollIntervalSec,
    required this.priorityOrderOfServices,
    required this.spotifyDirectFallback,
    required this.cloudSpotifyFallback,
    required this.localSonosFallback,
    required this.nativeLocalSonosFallback,
    required this.nativeLocalSonosCoordinatorDiscMethod,
    required this.nativeLocalSonosMaxHostsPerCoordinatorDisc,
    required this.nativeLocalSonosHealthCheckSec,
    required this.nativeLocalSonosHealthCheckRetry,
    required this.nativeLocalSonosHealthCheckTimeoutSec,
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
  final bool enableHomeTrackProgress;
  final int? nativeSonosPollIntervalSec;
  final int? nativeLocalSonosTrackProgressPollIntervalSec;
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
  final String nativeLocalSonosCoordinatorDiscMethod;
  final int nativeLocalSonosMaxHostsPerCoordinatorDisc;
  final int nativeLocalSonosHealthCheckSec;
  final int nativeLocalSonosHealthCheckRetry;
  final int nativeLocalSonosHealthCheckTimeoutSec;
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
  final override =
      _getEnv('Environment', 'PLATFORM_MODE')?.toLowerCase().trim();
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
      return 'WEB';
    case ClientPlatformMode.macos:
      return 'MACOS';
    case ClientPlatformMode.windows:
      return 'WINDOWS';
    case ClientPlatformMode.linux:
      return 'LINUX';
    case ClientPlatformMode.android:
      return 'ANDROID';
    case ClientPlatformMode.ios:
      return 'IOS';
    case ClientPlatformMode.embedded:
      return 'EMBEDDED';
    case ClientPlatformMode.defaultMode:
      return 'DEFAULT';
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
  final api = _getEnv('Server', 'API_BASE_URL') ?? 'http://localhost:5001';
  final ws =
      _getEnv('WebSocket', 'BASE_URL') ?? 'ws://localhost:5002/events/media';
  final flavor = _getEnv('Environment', 'FLAVOR') ?? 'dev';
  final logLevel = (_getEnv('Server', 'LOG_LEVEL') ?? 'INFO').toUpperCase();
  final apiSslVerify =
      _parseBool(_getEnv('Server', 'API_SSL_VERIFY'), fallback: true);
  final wsSslVerify =
      _parseBool(_getEnv('WebSocket', 'SSL_VERIFY'), fallback: true);
  final wsRetryIntervalMs =
      _parseInt(_getEnv('WebSocket', 'RETRY_INTERVAL_MS'), fallback: 3000);
  final wsRetryActiveSec =
      _parseInt(_getEnv('WebSocket', 'RETRY_ACTIVE_SEC'), fallback: 60);
  final wsRetryCooldownSec =
      _parseInt(_getEnv('WebSocket', 'RETRY_COOLDOWN_SEC'), fallback: 60);
  int parseRetryTimeSec(String section, String key, {int defaultValue = 0}) {
    return _parseInt(_getEnv(section, key), fallback: defaultValue);
  }

  final wsRetryWindowSec = parseRetryTimeSec('WebSocket', 'RETRY_WINDOW_SEC');
  final directSpotifyTimeoutSec =
      _parseInt(_getEnv('DirectSpotify', 'TIMEOUT_SEC'), fallback: 3);
  final cloudSpotifyPollIntervalSec =
      _parseInt(_getEnv('CloudSpotify', 'POLL_INTERVAL_SEC'), fallback: 3);
  // Sonos poll interval: null or 0 means let the server decide
  final sonosPollIntervalSecRaw =
      _parseInt(_getEnv('LocalSonos', 'POLL_INTERVAL_SEC'), fallback: 0);
  final sonosPollIntervalSec =
      sonosPollIntervalSecRaw <= 0 ? null : sonosPollIntervalSecRaw;
  final maxAvatarsPerUser =
      _parseInt(_getEnv('Server', 'MAX_AVATARS_PER_USER'), fallback: 5);
  final directSpotifyPollIntervalSec =
      _parseInt(_getEnv('DirectSpotify', 'POLL_INTERVAL_SEC'), fallback: 3);
  final directSpotifyRetryIntervalSec =
      _parseInt(_getEnv('DirectSpotify', 'RETRY_INTERVAL_SEC'), fallback: 3);
  final directSpotifyRetryTimeSec =
      parseRetryTimeSec('DirectSpotify', 'RETRY_TIME_SEC');
  final directSpotifyRetryCooldownSec =
      _parseInt(_getEnv('DirectSpotify', 'RETRY_COOLDOWN_SEC'), fallback: 30);
  final wsForceReconnIdleSec =
      _parseInt(_getEnv('WebSocket', 'FORCE_RECONN_IDLE_SEC'), fallback: 30);
  final directSpotifyApiSslVerify =
      _parseBool(_getEnv('DirectSpotify', 'API_SSL_VERIFY'), fallback: true);
  final directSpotifyApiBaseUrl =
      _getEnv('DirectSpotify', 'API_BASE_URL') ?? 'https://api.spotify.com/v1';
  final nativeSonosPollIntervalSecRaw =
      _parseInt(_getEnv('NativeLocalSonos', 'POLL_INTERVAL_SEC'), fallback: 0);
  final nativeSonosPollIntervalSec = (nativeSonosPollIntervalSecRaw <= 0)
      ? null
      : nativeSonosPollIntervalSecRaw;
  final nativeTrackProgressPollIntervalSecRaw = _parseInt(
      _getEnv('NativeLocalSonos', 'TRACK_PROGRESS_POLL_INTERVAL_SEC'),
      fallback: 0);
  final nativeTrackProgressPollIntervalSec =
      (nativeTrackProgressPollIntervalSecRaw <= 0)
          ? null
          : nativeTrackProgressPollIntervalSecRaw;
  final enableHomeTrackProgress = _parseBool(
      _getEnv('NowPlayingHomeWidget', 'ENABLE_TRACK_PROGRESS'),
      fallback: false);

  // Parse service priority order based on platform mode
  final platformMode = _detectPlatformMode();
  final priorityEnvKey = _priorityKeyForMode(platformMode);

  // Parse primary priority list; if empty/invalid, fall back to DEF_PRIORITY_ORDER_OF_SERVICES.
  final allowedServices = _allowedServicesForMode(platformMode);
  final primaryPriorityString = _getEnv('ServicePriority', priorityEnvKey);
  final defaultPriorityString = _getEnv('ServicePriority', 'DEFAULT');

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
    timeoutSec: _parseInt(_getEnv('DirectSpotify', 'FALLBACK_TIMEOUT_SEC'),
        fallback: 5),
    onError: _parseBool(_getEnv('DirectSpotify', 'FALLBACK_ON_ERROR'),
        fallback: true),
    errorThreshold: _parseInt(
        _getEnv('DirectSpotify', 'FALLBACK_ERROR_THRESHOLD'),
        fallback: 3),
    fallbackTimeThresholdSec: _parseInt(
        _getEnv('DirectSpotify', 'FALLBACK_TIME_THRESHOLD_SEC'),
        fallback: 10),
    retryIntervalSec: directSpotifyRetryIntervalSec,
    retryCooldownSec: directSpotifyRetryCooldownSec,
    retryTimeSec: directSpotifyRetryTimeSec,
  );

  // Parse Cloud Spotify fallback config
  final cloudSpotifyFallback = ServiceFallbackConfig(
    timeoutSec:
        _parseInt(_getEnv('CloudSpotify', 'FALLBACK_TIMEOUT_SEC'), fallback: 5),
    onError: _parseBool(_getEnv('CloudSpotify', 'FALLBACK_ON_ERROR'),
        fallback: true),
    errorThreshold: _parseInt(
        _getEnv('CloudSpotify', 'FALLBACK_ERROR_THRESHOLD'),
        fallback: 3),
    fallbackTimeThresholdSec: _parseInt(
        _getEnv('CloudSpotify', 'FALLBACK_TIME_THRESHOLD_SEC'),
        fallback: 10),
    retryIntervalSec:
        _parseInt(_getEnv('CloudSpotify', 'RETRY_INTERVAL_SEC'), fallback: 10),
    retryCooldownSec:
        _parseInt(_getEnv('CloudSpotify', 'RETRY_COOLDOWN_SEC'), fallback: 30),
    retryTimeSec: parseRetryTimeSec('CloudSpotify', 'RETRY_TIME_SEC'),
  );

  // Parse Local Sonos fallback config
  // NOTE: Sonos is event-driven (only emits on state change), so timeout is disabled by default (0)
  // Fallback for Sonos relies on WebSocket connection state, not data timeout
  final localSonosFallback = ServiceFallbackConfig(
    timeoutSec: _parseInt(_getEnv('LocalSonos', 'FALLBACK_TIMEOUT_SEC'),
        fallback: 0), // 0 = disabled (event-driven)
    onError:
        _parseBool(_getEnv('LocalSonos', 'FALLBACK_ON_ERROR'), fallback: true),
    errorThreshold: _parseInt(_getEnv('LocalSonos', 'FALLBACK_ERROR_THRESHOLD'),
        fallback: 3),
    fallbackTimeThresholdSec: _parseInt(
        _getEnv('LocalSonos', 'FALLBACK_TIME_THRESHOLD_SEC'),
        fallback: 10),
    retryIntervalSec:
        _parseInt(_getEnv('LocalSonos', 'RETRY_INTERVAL_SEC'), fallback: 10),
    retryCooldownSec:
        _parseInt(_getEnv('LocalSonos', 'RETRY_COOLDOWN_SEC'), fallback: 30),
    retryTimeSec: parseRetryTimeSec('LocalSonos', 'RETRY_TIME_SEC'),
  );

  // Parse Native Local Sonos fallback config (on-device bridge)
  final nativeLocalSonosFallback = ServiceFallbackConfig(
    timeoutSec: _parseInt(_getEnv('NativeLocalSonos', 'FALLBACK_TIMEOUT_SEC'),
        fallback: 0), // 0 = disabled (event-driven)
    onError: _parseBool(_getEnv('NativeLocalSonos', 'FALLBACK_ON_ERROR'),
        fallback: true),
    errorThreshold: _parseInt(
        _getEnv('NativeLocalSonos', 'FALLBACK_ERROR_THRESHOLD'),
        fallback: 3),
    fallbackTimeThresholdSec: _parseInt(
        _getEnv('NativeLocalSonos', 'FALLBACK_TIME_THRESHOLD_SEC'),
        fallback: 10),
    retryIntervalSec: _parseInt(
        _getEnv('NativeLocalSonos', 'RETRY_INTERVAL_SEC'),
        fallback: 10),
    retryCooldownSec: _parseInt(
        _getEnv('NativeLocalSonos', 'RETRY_COOLDOWN_SEC'),
        fallback: 30),
    retryTimeSec: parseRetryTimeSec('NativeLocalSonos', 'RETRY_TIME_SEC'),
  );

  // Parse Local Sonos auto-switch settings (state-based wait times)
  // 0 = disabled (don't cycle for that state)
  final localSonosPausedWaitSec =
      _parseInt(_getEnv('LocalSonos', 'PAUSED_WAIT_SEC'), fallback: 0);
  final localSonosStoppedWaitSec =
      _parseInt(_getEnv('LocalSonos', 'STOPPED_WAIT_SEC'), fallback: 30);
  final localSonosIdleWaitSec =
      _parseInt(_getEnv('LocalSonos', 'IDLE_WAIT_SEC'), fallback: 3);

  // Native local Sonos wait times (defaults to match local sonos if unset)
  final nativeLocalSonosPausedWaitSec = _parseInt(
      _getEnv('NativeLocalSonos', 'PAUSED_WAIT_SEC'),
      fallback: localSonosPausedWaitSec);
  final nativeLocalSonosStoppedWaitSec = _parseInt(
      _getEnv('NativeLocalSonos', 'STOPPED_WAIT_SEC'),
      fallback: localSonosStoppedWaitSec);
  final nativeLocalSonosIdleWaitSec = _parseInt(
      _getEnv('NativeLocalSonos', 'IDLE_WAIT_SEC'),
      fallback: localSonosIdleWaitSec);

  // Native Sonos coordinator discovery method
  final nativeLocalSonosCoordinatorDiscMethod = (() {
    const fallback = 'lmp_zgs';
    final raw = _getEnv('NativeLocalSonos', 'COORDINATOR_DISC_METHOD')?.trim();
    if (raw == null || raw.isEmpty) return fallback;
    final lowered = raw.toLowerCase();
    return (lowered == 'lmp_zgs' || lowered == 'zgs_lmp') ? lowered : fallback;
  })();

  // Parse Spotify paused wait time
  final spotifyPausedWaitSec = _parseInt(
      _getEnv('GeneralService', 'SPOTIFY_PAUSED_WAIT_SEC'),
      fallback: 5);

  // Parse service cycling settings
  final enableServiceCycling =
      _parseBool(_getEnv('GeneralService', 'ENABLE_CYCLING'), fallback: true);
  final serviceCycleResetSec =
      _parseInt(_getEnv('GeneralService', 'CYCLE_RESET_SEC'), fallback: 30);

  // Native Sonos health check configuration
  final nativeLocalSonosHealthCheckSec =
      _parseInt(_getEnv('NativeLocalSonos', 'HEALTH_CHECK_SEC'), fallback: 0);
  final nativeLocalSonosHealthCheckRetry =
      _parseInt(_getEnv('NativeLocalSonos', 'HEALTH_CHECK_RETRY'), fallback: 0);
  final nativeLocalSonosHealthCheckTimeoutSec = _parseInt(
      _getEnv('NativeLocalSonos', 'HEALTH_CHECK_TIMEOUT_SEC'),
      fallback: 5);

  // Maximum hosts to attempt during coordinator discovery (0 = unlimited)
  final nativeLocalSonosMaxHostsPerCoordinatorDisc = _parseInt(
      _getEnv('NativeLocalSonos', 'MAX_HOSTS_PER_COORDINATOR_DISC'),
      fallback: 4);

  // Parse global service settings
  final serviceTransitionGraceSec =
      _parseInt(_getEnv('GeneralService', 'TRANSITION_GRACE_SEC'), fallback: 2);

  // Idle reset safeguards
  final serviceIdleCycleResetSec =
      _parseInt(_getEnv('GeneralService', 'IDLE_CYCLE_RESET_SEC'), fallback: 0);
  final serviceIdleTimeSec =
      _parseInt(_getEnv('GeneralService', 'IDLE_TIME_SEC'), fallback: 0);

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
    enableHomeTrackProgress: enableHomeTrackProgress,
    nativeLocalSonosTrackProgressPollIntervalSec:
        nativeTrackProgressPollIntervalSec,
    nativeSonosPollIntervalSec: nativeSonosPollIntervalSec,
    priorityOrderOfServices: priorityOrderOfServices,
    spotifyDirectFallback: spotifyDirectFallback,
    cloudSpotifyFallback: cloudSpotifyFallback,
    localSonosFallback: localSonosFallback,
    nativeLocalSonosFallback: nativeLocalSonosFallback,
    nativeLocalSonosCoordinatorDiscMethod:
        nativeLocalSonosCoordinatorDiscMethod,
    nativeLocalSonosMaxHostsPerCoordinatorDisc:
        nativeLocalSonosMaxHostsPerCoordinatorDisc,
    nativeLocalSonosHealthCheckSec: nativeLocalSonosHealthCheckSec,
    nativeLocalSonosHealthCheckRetry: nativeLocalSonosHealthCheckRetry,
    nativeLocalSonosHealthCheckTimeoutSec:
        nativeLocalSonosHealthCheckTimeoutSec,
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
  const path = 'conf/.env';
  try {
    final content = await rootBundle.loadString(path);
    _envSections = _parseEnvWithSections(content);
    _envLogger.info('Loaded env sections: ${_envSections.keys.join(', ')}');
  } catch (e, st) {
    _envLogger.severe('Failed to load $path: $e', e, st);
    _envSections = {};
  }
}
