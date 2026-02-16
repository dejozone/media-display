import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/events_ws_service.dart';
import 'package:media_display/src/services/service_health.dart';
import 'package:media_display/src/services/service_priority_manager.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/spotify_direct_service.dart';
import 'package:media_display/src/services/native_sonos_service.dart';
import 'package:media_display/src/services/native_sonos_bridge.dart';
import 'package:media_display/src/services/user_service.dart';
import 'package:media_display/src/utils/logging.dart';

final _logger = appLogger('ServiceOrchestrator');

void _log(String message, {Level level = Level.INFO}) {
  _logger.log(level, message);
}

/// Unified playback state from the active service
@immutable
class UnifiedPlaybackState {
  const UnifiedPlaybackState({
    this.isPlaying = false,
    this.track,
    this.playback,
    this.device,
    this.provider,
    this.activeService,
    this.error,
    this.isConnected = false,
    this.isLoading = false,
  });

  /// Whether music is currently playing
  final bool isPlaying;

  /// Track information
  final Map<String, dynamic>? track;

  /// Playback information (progress, status)
  final Map<String, dynamic>? playback;

  /// Device information
  final Map<String, dynamic>? device;

  /// Provider (spotify, sonos)
  final String? provider;

  /// Currently active service
  final ServiceType? activeService;

  /// Error message if any
  final String? error;

  /// Whether the active service is connected
  final bool isConnected;

  /// Whether we're in a loading/transition state
  final bool isLoading;

  /// Check if we have valid playback data
  bool get hasData =>
      track != null && (track!['title'] as String?)?.isNotEmpty == true;

  /// Check if this is a "stopped" state (no active playback)
  bool get isStopped {
    if (playback == null) return true;
    final status = playback!['status'] as String?;
    return status == 'stopped' || (track?['title'] as String?)?.isEmpty == true;
  }

  UnifiedPlaybackState copyWith({
    bool? isPlaying,
    Map<String, dynamic>? track,
    Map<String, dynamic>? playback,
    Map<String, dynamic>? device,
    String? provider,
    ServiceType? activeService,
    String? error,
    bool? isConnected,
    bool? isLoading,
    bool clearError = false,
    bool clearTrack = false,
    bool clearActiveService = false,
  }) {
    return UnifiedPlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      track: clearTrack ? null : (track ?? this.track),
      playback: playback ?? this.playback,
      device: device ?? this.device,
      provider: provider ?? this.provider,
      activeService:
          clearActiveService ? null : (activeService ?? this.activeService),
      error: clearError ? null : (error ?? this.error),
      isConnected: isConnected ?? this.isConnected,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// Orchestrates between direct Spotify polling and cloud service (WebSocket)
class ServiceOrchestrator extends Notifier<UnifiedPlaybackState> {
  Timer? _timeoutTimer;
  Timer? _dataWatchTimer;
  Timer? _servicePausedTimer;
  Timer? _cycleResetTimer;
  Timer? _idleResetTimer;
  DateTime? _lastDataTime;
  DateTime? _lastPlayingTime;
  DateTime? _lastIdleResetAt;

  bool _initialized = false;
  bool _authInitListenerStarted = false;

  // Service cycling state
  ServiceType? _pausedService;
  final Set<ServiceType> _checkedNotPlaying = {};
  bool _waitingForPrimaryResume = false;
  ServiceType? _originalPrimaryService;

  // Track last playing state per service
  final Map<ServiceType, bool> _lastIsPlaying = {};

  // Service health tracking
  final Map<String, ServiceHealthState> _serviceHealth = {};

  // Ensure we register listeners only once per notifier lifecycle
  bool _watchersStarted = false;

  // Suppress priority change handling during explicit resets to avoid
  // transient null-service churn/config pushes.
  bool _suppressPriorityChanges = false;

  // Track if we've already triggered Sonos discovery for the current Speaker device
  // Reset when device changes or when Sonos data is received
  String? _lastSpeakerDeviceName;
  bool _sonosDiscoveryTriggered = false;
  bool _sonosBackendEnabledForSpeaker = false;

  EnvConfig get _config => ref.read(envConfigProvider);

  bool get _nativeSonosSupported => createNativeSonosBridge().isSupported;

  @override
  UnifiedPlaybackState build() {
    ref.onDispose(() {
      _timeoutTimer?.cancel();
      _dataWatchTimer?.cancel();
      _servicePausedTimer?.cancel();
      _cycleResetTimer?.cancel();
      _idleResetTimer?.cancel();
    });

    // Initialize asynchronously
    Future.microtask(() => _initialize());

    return const UnifiedPlaybackState(isLoading: true);
  }

  Future<void> _initialize() async {
    if (_initialized) return;

    // Defer all orchestration until user is authenticated. The Home page may
    // touch this notifier on the login screen; we should stay idle there.
    final auth = ref.read(authStateProvider);
    if (!auth.isAuthenticated) {
      _log('Auth not available; deferring initialization until login');

      // Listen once for auth to become available, then retry initialization.
      if (!_authInitListenerStarted) {
        _authInitListenerStarted = true;
        ref.listen<AuthState>(authStateProvider, (prev, next) {
          if (next.isAuthenticated) {
            _log('Auth available; resuming initialization');
            _initialize();
          }
        });
      }
      return;
    }

    _initialized = true;

    // Set up service status callback to receive health updates from WebSocket
    ref.read(eventsWsProvider.notifier).onServiceStatus = _handleServiceStatus;

    // Log platform mode and configured priority order for visibility
    final env = _config;
    _log('Platform mode=${env.platformMode.label} priority='
        '${env.priorityOrderOfServices.map((s) => s.toConfigString()).join(',')}');

    // Set up probe callback for service recovery
    ref
        .read(servicePriorityProvider.notifier)
        .setProbeCallback(_probeServiceForRecovery);

    // Load user settings to determine which services are enabled
    final settingsLoaded = await _loadServicesSettings();

    // Start listening to service changes
    _startServiceWatchers();

    // Seed last-playing timestamp so idle reset doesn't fire immediately
    _lastPlayingTime ??= DateTime.now();
    _startIdleResetWatcher();

    // Re-enable priority change handling now that initialization is ready
    _suppressPriorityChanges = false;

    // Run the full initial activation flow (like first login) so config is sent
    // even after a reset. Skip if settings failed to load (e.g., temporary
    // auth issues) to avoid activating with an empty priority list.
    if (settingsLoaded) {
      ref.read(servicePriorityProvider.notifier).restartInitialActivation();
    } else {
      _log('Skipping initial activation because settings failed to load');
    }
  }

  /// Probe a service for recovery (used by priority manager)
  /// Returns true if service is healthy, false otherwise
  /// NOTE: Only directSpotify is probed client-side. Cloud services have recovery handled by server.
  Future<bool> _probeServiceForRecovery(ServiceType service) async {
    // _log('Probing $service for recovery');

    switch (service) {
      case ServiceType.directSpotify:
        // Direct Spotify - probe via client-side API call
        return ref.read(spotifyDirectProvider.notifier).probeService();

      case ServiceType.cloudSpotify:
        // Cloud Spotify: request server health via WebSocket; rely on server response
        ref
            .read(eventsWsProvider.notifier)
            .requestServiceStatus(const ['spotify']);
        return false;

      case ServiceType.localSonos:
        // Local Sonos: request server health via WebSocket; rely on server response
        ref
            .read(eventsWsProvider.notifier)
            .requestServiceStatus(const ['sonos']);
        return false;

      case ServiceType.nativeLocalSonos:
        // Native Sonos: probe locally (if supported)
        return ref.read(nativeSonosProvider.notifier).probe();
    }
  }

  Future<bool> _loadServicesSettings() async {
    try {
      final user = await ref.read(userServiceProvider).fetchMe();
      final userId = user['id']?.toString() ?? '';
      if (userId.isEmpty) {
        return false;
      }

      final settings =
          await ref.read(settingsServiceProvider).fetchSettingsForUser(userId);
      final spotifyEnabled = settings['spotify_enabled'] == true;
      final sonosEnabled = settings['sonos_enabled'] == true;

      _log('Settings loaded: spotify=$spotifyEnabled, sonos=$sonosEnabled');

      // Update service priority with enabled services
      ref.read(servicePriorityProvider.notifier).updateEnabledServices(
            spotifyEnabled: spotifyEnabled,
            sonosEnabled: sonosEnabled,
            nativeSonosSupported: _nativeSonosSupported,
          );

      return true;
    } catch (e) {
      _log('Failed to load settings: $e');
      return false;
    }
  }

  void _startServiceWatchers() {
    if (_watchersStarted) return;
    _watchersStarted = true;

    // Watch auth state changes to stop everything on logout
    ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (prev?.isAuthenticated == true && !next.isAuthenticated) {
        _log('User logged out - stopping all services');
        _stopAllServices();
      }
    });

    // Watch service priority changes
    ref.listen<ServicePriorityState>(servicePriorityProvider, (prev, next) {
      _handleServicePriorityChange(prev, next);
    });

    // Watch direct Spotify service
    ref.listen<SpotifyDirectState>(spotifyDirectProvider, (prev, next) {
      _handleDirectSpotifyChange(next);
    });

    // Watch native/local Sonos bridge
    ref.listen<NativeSonosState>(nativeSonosProvider, (prev, next) {
      _handleNativeSonosChange(next);
    });

    // Watch WebSocket/cloud service
    ref.listen<NowPlayingState>(eventsWsProvider, (prev, next) {
      _handleCloudServiceChange(next);
    });

    // Start data timeout watcher
    _startDataTimeoutWatcher();
  }

  void _handleServicePriorityChange(
      ServicePriorityState? prev, ServicePriorityState next) {
    if (_suppressPriorityChanges) {
      return;
    }

    final currentService = next.currentService;
    final prevService = prev?.currentService;
    final prevEnabled = prev?.enabledServices ?? const {};
    final sonosWasEnabled = prevEnabled.contains(ServiceType.nativeLocalSonos);

    // Keep native Sonos running when switching away so re-activation is fast.
    // Only tear down when the user disables Sonos entirely or during global
    // stop/reset paths.
    final sonosDisabled =
        !next.enabledServices.contains(ServiceType.nativeLocalSonos);
    final sonosNewlyDisabled = sonosWasEnabled && sonosDisabled;
    if (sonosNewlyDisabled &&
        currentService != ServiceType.nativeLocalSonos) {
      _log('Stopping native Sonos bridge (reason=sonos disabled)');
      ref.read(nativeSonosProvider.notifier).stop();
    }

    // If the current service just recovered while remaining the same logical
    // service, re-run activation so the orchestrator restarts that service
    // (e.g., native Sonos bridge) without requiring a priority change.
    if (currentService != null && currentService == prevService) {
      final prevStatus = prev?.serviceStatuses[currentService];
      final nextStatus = next.serviceStatuses[currentService];
      final wasRecovering =
          prev?.recoveryStates.containsKey(currentService) ?? false;
      final nowHealthy = nextStatus == ServiceStatus.active &&
          !(next.recoveryStates.containsKey(currentService)) &&
          (wasRecovering || prevStatus != ServiceStatus.active);

      if (nowHealthy) {
        _log('Reactivating $currentService after recovery');
        _activateService(currentService, isFallback: false);
        return;
      }
    }

    // When priority manager is re-running initial activation after reconnect,
    // it briefly has no current service while it prepares to select one. If
    // there are enabled services, skip handling to avoid emitting "No service
    // to activate" and sending a user-settings config before the service is
    // chosen. If all services are disabled, allow normal handling so we still
    // send the disabling config.
    if (currentService == null && next.enabledServices.isNotEmpty) {
      return;
    }

    if (currentService != prevService) {
      // Prevent switching to a lower-priority Spotify service during a global
      // pause when the current service is still healthy. In this state the
      // user explicitly paused playback; we should stay on the chosen service
      // until a higher-priority service recovers instead of dropping to a
      // lower tier (e.g., direct -> cloud).
      if (_shouldHoldGlobalPause(prevService, currentService, next)) {
        ref
            .read(servicePriorityProvider.notifier)
            .activateService(prevService!);
        return;
      }

      // Check if this is a switch to a higher-priority service (not a fallback due to cycling)
      // If so, reset cycling state to allow fresh evaluation of the new service
      bool isFallback = false;
      if (currentService != null) {
        bool shouldResetCycling = false;

        if (prevService == null) {
          // Initial activation - reset cycling state
          shouldResetCycling = true;
        } else {
          final serviceList = _config.priorityOrderOfServices;
          final currentPriority = serviceList.indexOf(currentService);
          final previousPriority = serviceList.indexOf(prevService);

          // Lower index = higher priority
          // If switching to higher priority (or previous not in list), reset cycling
          // This happens on WS reconnect when a cloud service becomes available
          if (currentPriority >= 0 &&
              (previousPriority < 0 || currentPriority < previousPriority)) {
            shouldResetCycling = true;
          } else if (currentPriority > previousPriority) {
            // Switching to lower priority = fallback
            isFallback = true;
          }
        }

        if (shouldResetCycling) {
          _cancelPauseTimer();
          _resetCyclingState();
        }
      }

      // Update state with new service - preserve existing track data
      state = state.copyWith(
        activeService: currentService,
        isLoading: next.isTransitioning,
        clearError: true,
      );

      // Start/stop services based on new active service
      _activateService(currentService, isFallback: isFallback);
    }
  }

  void _activateService(ServiceType? service, {bool isFallback = false}) {
    if (service == null) {
      _log('No service to activate - sending user settings config');
      // Stop direct polling if running
      ref.read(spotifyDirectProvider.notifier).stopPolling();
      // Send config based on user settings (not disabling everything)
      // This ensures server keeps polling services that user has enabled
      // even if they're temporarily unavailable on client side
      _sendConfigForUserSettings();
      return;
    }

    // Avoid activating cloud services that are waiting for server recovery
    final priorityState = ref.read(servicePriorityProvider);
    if (service.isCloudService &&
        priorityState.awaitingRecovery.contains(service)) {
      // Allow activation if we're in a fallback path OR if no other available
      // enabled service exists (last resort so we don't get stuck).
      final hasOtherAvailable = _config.priorityOrderOfServices.any((s) {
        if (s == service) return false;
        if (!priorityState.enabledServices.contains(s)) return false;
        return priorityState.isServiceAvailable(s);
      });

      if (!isFallback && hasOtherAvailable) {
        _log('$service awaiting recovery - not activating');
        return;
      } else {
        _log(
            '$service awaiting recovery but activating (fallback/last resort)');
      }
    }

    // Clear previous health state for this service so any new failure
    // is treated as a "first time" failure, not a continuation
    // BUT don't clear during fallback - we need to keep the failed service's
    // health state so we know to keep server polling for recovery
    if (!isFallback) {
      _clearHealthState(service);
    }

    if (service.isDirectPolling) {
      _activateDirectSpotify(isFallback: isFallback);
    } else if (service.isNativeSonos) {
      _activateNativeSonos(isFallback: isFallback);
    } else {
      // cloud_spotify or local_sonos
      _activateCloudService(service, isFallback: isFallback);
    }
  }

  /// Clear the health state for a service (e.g., when activating after recovery)
  void _clearHealthState(ServiceType service) {
    final provider = service == ServiceType.localSonos ? 'sonos' : 'spotify';
    if (_serviceHealth.containsKey(provider)) {
      _serviceHealth.remove(provider);
    }
  }

  /// Send config to server based on user settings (no specific active service)
  void _sendConfigForUserSettings() {
    final channel = ref.read(eventsWsProvider.notifier);
    channel.sendConfigForUserSettings();
  }

  void _activateDirectSpotify({bool isFallback = false}) {
    // Stop any direct polling first (in case switching from another mode)
    // Start direct polling
    ref.read(spotifyDirectProvider.notifier).startDirectPolling();

    // Send WebSocket config to tell backend not to poll
    // (we're polling directly from client)
    // Keep sonos enabled if we're waiting for it to resume
    final keepSonosBase = isFallback ||
        (_waitingForPrimaryResume &&
            _originalPrimaryService == ServiceType.localSonos);
    final keepSonos = keepSonosBase && isServiceHealthy(ServiceType.localSonos);

    // Keep spotify polling enabled if cloudSpotify is unhealthy
    // This allows the server to continue its retry loop and emit healthy status
    // when it recovers, so we can switch back to cloudSpotify
    // NOTE: Check _serviceHealth directly, not priority.unhealthyServices,
    // because unhealthyServices is synced after the service switch
    final spotifyHealth = _serviceHealth['spotify'];
    final keepSpotifyForRecovery =
        spotifyHealth != null && !spotifyHealth.status.isHealthy;

    ref.read(eventsWsProvider.notifier).sendConfigForService(
          ServiceType.directSpotify,
          keepSonosEnabled: keepSonos,
          keepSpotifyPollingForRecovery: keepSpotifyForRecovery,
          caller: '_activateDirectSpotify',
        );

    // Reset timeout timer
    _resetTimeoutTimer();
  }

  void _activateCloudService(ServiceType service, {bool isFallback = false}) {
    // Stop direct polling if it was running
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    // Connect/reconnect WebSocket and send config for this service
    // Keep other services enabled only when explicitly cycling/fallback. When
    // cloudSpotify is active, do NOT keep Sonos enabled by default to avoid
    // churny configs; Sonos will be enabled only when explicitly requested.
    final keepSonosBase = (isFallback ||
        (_waitingForPrimaryResume &&
            _originalPrimaryService == ServiceType.localSonos));
    final keepSonos = keepSonosBase && isServiceHealthy(ServiceType.localSonos);

    // When running on Sonos during fallback, keep Spotify polling so it can
    // recover and take over when healthy (higher priority rules apply).
    final keepSpotifyForRecovery =
        isFallback && service == ServiceType.localSonos;
    ref.read(eventsWsProvider.notifier).sendConfigForService(
          service,
          keepSonosEnabled: keepSonos,
          keepSpotifyPollingForRecovery: keepSpotifyForRecovery,
          caller: '_activateCloudService',
        );

    // Reset timeout timer
    _resetTimeoutTimer();
  }

  void _activateNativeSonos({bool isFallback = false}) {
    if (!_nativeSonosSupported) {
      _log(
          'Native local Sonos not supported on this platform; skipping activation');
      ref.read(servicePriorityProvider.notifier).reportError(
          ServiceType.nativeLocalSonos,
          error: 'native bridge not supported on this platform');
      return;
    }

    _log('Activating native local Sonos (fallback=$isFallback)');

    // Stop direct polling if it was running
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    // Tell backend to pause streaming while native bridge is active. We still
    // keep tokens available for Spotify fallback.
    ref.read(eventsWsProvider.notifier).sendConfigForService(
          ServiceType.nativeLocalSonos,
          keepSonosEnabled: false,
          keepSpotifyPollingForRecovery: false,
          caller: '_activateNativeSonos',
        );

    // Start native bridge (event-driven; pollInterval optional)
    final pollInterval = _config.nativeSonosPollIntervalSec ??
        (_config.nativeLocalSonosFallback.timeoutSec > 0
            ? _config.nativeLocalSonosFallback.timeoutSec
            : null);
    _log('Starting native Sonos bridge with pollIntervalSec=$pollInterval');
    ref.read(nativeSonosProvider.notifier).start(
          pollIntervalSec: pollInterval,
        );

    _resetTimeoutTimer();
  }

  void _handleDirectSpotifyChange(SpotifyDirectState spotifyState) {
    final priority = ref.read(servicePriorityProvider);

    // Check if primary service has resumed (when we're waiting for it)
    if (_waitingForPrimaryResume &&
        _originalPrimaryService == ServiceType.directSpotify &&
        spotifyState.payload != null) {
      final playback =
          spotifyState.payload!['playback'] as Map<String, dynamic>?;
      final isPlaying = playback?['is_playing'] as bool? ?? false;

      if (isPlaying) {
        _log('Primary service directSpotify resumed playing!');
        _handlePrimaryServiceResumed();
        return;
      }
    }

    // Process when direct_spotify is active, OR when cloud services are down and
    // direct polling is running so the UI can still update while WS is retrying.
    final wsState = ref.read(eventsWsProvider);
    final directIsActive = priority.currentService == ServiceType.directSpotify;
    final cloudUnavailable = !wsState.connected && wsState.wsRetrying;
    if (!directIsActive && !cloudUnavailable) return;

    // Check for errors
    if (spotifyState.error != null) {
      // Check if it's a 401 error (handled separately - triggers token refresh, not fallback)
      if (spotifyState.error!.contains('401') ||
          spotifyState.error!.contains('Unauthorized')) {
        _log('Direct Spotify 401 - token refresh triggered');
        return; // Don't trigger fallback for auth errors
      }

      // Report error to priority manager
      ref
          .read(servicePriorityProvider.notifier)
          .reportError(ServiceType.directSpotify, error: spotifyState.error);
    }

    // Check for fallback mode
    if (spotifyState.mode == SpotifyPollingMode.fallback ||
        spotifyState.mode == SpotifyPollingMode.offline) {
      _log(
          'Direct Spotify in fallback/offline mode - triggering service fallback');
      ref.read(servicePriorityProvider.notifier).reportError(
          ServiceType.directSpotify,
          error: 'mode=${spotifyState.mode.name}');
      return;
    }

    // Process payload if available
    if (spotifyState.payload != null) {
      final playback =
          spotifyState.payload!['playback'] as Map<String, dynamic>?;
      final isPlaying = playback?['is_playing'] as bool? ?? false;
      final wasPlaying = _lastIsPlaying[ServiceType.directSpotify] ?? false;
      _lastIsPlaying[ServiceType.directSpotify] = isPlaying;

      if (isPlaying) {
        // Playing - cancel pause timer
        _cancelPauseTimer();

        // Only reset cycling state if this IS the primary service we're waiting for
        // If we're on a fallback service and it's playing, keep waiting for primary
        if (!_waitingForPrimaryResume ||
            _originalPrimaryService == ServiceType.directSpotify) {
          _resetCyclingState();
        }
      } else if (_config.enableServiceCycling) {
        // Not playing - handle pause detection for cycling
        // Only start cycling if we're NOT already waiting for primary to resume
        if (!_waitingForPrimaryResume) {
          // Only log state change (was playing → not playing)
          if (wasPlaying) {
            _log('Spotify stopped playing');
          }
          _handleServicePaused(ServiceType.directSpotify);
        }
      }

      _processPayload(spotifyState.payload!, ServiceType.directSpotify);
    }
  }

  void _handleNativeSonosChange(NativeSonosState bridgeState) {
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;
    final isCurrent = currentService == ServiceType.nativeLocalSonos;

    _log(
        'NativeSonos update: isCurrent=$isCurrent connected=${bridgeState.connected} '
        'hasPayload=${bridgeState.payload != null} error=${bridgeState.error}');

    // Ignore background updates when service not active and no payload
    if (!isCurrent && bridgeState.payload == null) {
      return;
    }

    if (!bridgeState.connected) {
      if (isCurrent) {
        // Allow a brief startup period when the bridge is running but not yet connected.
        if (bridgeState.isRunning) {
          _log(
              'NativeSonos starting up; waiting for connection before fallback');
          return;
        }
        // If we still have a payload, avoid penalizing immediately (likely a restart)
        if (bridgeState.payload != null) {
          _log('NativeSonos restart with cached payload; skip error report');
          return;
        }
        _log('NativeSonos not connected; reporting error/fallback');
        ref.read(servicePriorityProvider.notifier).reportError(
            ServiceType.nativeLocalSonos,
            error: bridgeState.error ?? 'disconnected');
      }
      return;
    }

    if (bridgeState.payload == null) return;

    final payload = bridgeState.payload!;
    final data = payload['data'] as Map<String, dynamic>? ?? const {};
    final track = data['track'] as Map<String, dynamic>?;
    final playback = data['playback'] as Map<String, dynamic>?;
    final device = data['device'] as Map<String, dynamic>?;
    final provider =
        data['provider'] as String? ?? payload['provider'] as String?;
    final isPlaying = playback?['is_playing'] as bool? ?? false;
    final status = playback?['status'] as String?;
    final hasTrackInfo = _hasValidTrackInfo(track);
    final statusLower = status?.toLowerCase() ?? '';
    final startupWithoutTrack = isCurrent &&
        !hasTrackInfo &&
        (statusLower.isEmpty ||
            statusLower == 'unknown' ||
            statusLower == 'idle');

    _lastIsPlaying[ServiceType.nativeLocalSonos] = isPlaying;

    if (isPlaying) {
      _cancelPauseTimer();
      if (!_waitingForPrimaryResume ||
          _originalPrimaryService == ServiceType.nativeLocalSonos) {
        _resetCyclingState();
      }
    } else if (_config.enableServiceCycling &&
        isCurrent &&
        !_waitingForPrimaryResume &&
        !startupWithoutTrack) {
      _handleSonosPausedWithStatus(
        ServiceType.nativeLocalSonos,
        status,
        hasTrackInfo: hasTrackInfo,
      );
    }

    // Update UI/state when active, or when it is playing, or when it has track
    // info and the current service is not actively playing.
    final currentPlaying =
        currentService != null && (_lastIsPlaying[currentService] ?? false);
    final shouldUpdateUI =
        isCurrent || isPlaying || (hasTrackInfo && !currentPlaying);

    if (shouldUpdateUI) {
      // Normalize to the flat shape expected by _processPayload
      _processPayload({
        'track': track,
        'playback': playback,
        'device': device,
        'provider': provider,
      }, ServiceType.nativeLocalSonos);

      // If a lower-priority service is active, promote native local Sonos now.
      if (!isCurrent) {
        _log('NativeSonos delivered payload; promoting to nativeLocalSonos');
        ref
            .read(servicePriorityProvider.notifier)
            .activateService(ServiceType.nativeLocalSonos);
      }
    }
  }

  void _handleCloudServiceChange(NowPlayingState wsState) {
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    // Determine the source of this payload
    ServiceType? dataSource;
    if (wsState.payload != null) {
      final provider = wsState.payload!['provider'] as String?;
      if (provider == 'sonos') {
        dataSource = ServiceType.localSonos;
      } else if (provider == 'spotify') {
        dataSource = ServiceType.cloudSpotify;
      }
    }

    // Handle primary service resume detection when waiting for it
    if (_waitingForPrimaryResume &&
        wsState.payload != null &&
        dataSource != null) {
      final playback = wsState.payload!['playback'] as Map<String, dynamic>?;
      final isPlaying = playback?['is_playing'] as bool? ?? false;

      if (dataSource == _originalPrimaryService && isPlaying) {
        _log('Primary service $dataSource resumed playing!');
        _handlePrimaryServiceResumed();
        // Don't return - continue to process the payload below
      }
    }

    // Check if this data source is enabled
    final isDataSourceEnabled =
        dataSource != null && priority.enabledServices.contains(dataSource);

    // Process if:
    // 1. A cloud service is currently active and this data is from that service, OR
    // 2. The data source is enabled (even if not currently active - for multi-source awareness)
    final isCurrentCloudService = currentService != null &&
        currentService.isCloudService &&
        (dataSource == currentService || dataSource == null);

    // If this is Sonos data and Sonos is enabled, always process it
    // This allows Sonos to be monitored even when Spotify Direct is active
    final shouldProcessSonosData =
        dataSource == ServiceType.localSonos && isDataSourceEnabled;

    if (!isCurrentCloudService && !shouldProcessSonosData) {
      return;
    }

    // Check connection status
    if (!wsState.connected) {
      // Only report errors if this is the current service
      if (isCurrentCloudService &&
          wsState.error != null &&
          !wsState.wsRetrying) {
        _log('Cloud service disconnected: ${wsState.error}');
        ref.read(servicePriorityProvider.notifier).reportError(currentService);
      }
      return;
    }

    // Determine which service to attribute this data to
    final effectiveService = dataSource ?? currentService;
    if (effectiveService == null) return;

    // Process payload if available
    if (wsState.payload != null) {
      final track = wsState.payload!['track'] as Map<String, dynamic>?;
      final playback = wsState.payload!['playback'] as Map<String, dynamic>?;
      final isPlaying = playback?['is_playing'] as bool? ?? false;
      _lastIsPlaying[effectiveService] = isPlaying;
      final hasTrackInfo = _hasValidTrackInfo(track);

      // Check if this data source is different from current active service
      final isFromDifferentService = effectiveService != currentService;

      // Check if current service is playing (to decide on switching)
      final currentServicePlaying =
          currentService != null && (_lastIsPlaying[currentService] ?? false);

      if (isPlaying) {
        // Playing - cancel pause timer
        _cancelPauseTimer();

        // If Sonos starts playing but we're on a different service, consider switching
        if (isFromDifferentService &&
            effectiveService == ServiceType.localSonos) {
          final priorityOrder = _config.priorityOrderOfServices;
          final idxCurrent = currentService == null
              ? -1
              : priorityOrder.indexOf(currentService);
          final idxSonos = priorityOrder.indexOf(ServiceType.localSonos);
          final currentHigherPriority =
              idxCurrent >= 0 && idxSonos >= 0 && idxCurrent < idxSonos;
          final currentHealthy =
              currentService == null ? false : isServiceHealthy(currentService);

          if (currentHigherPriority && currentHealthy) {
            _disableSonosBackend();
          } else {
            ref
                .read(servicePriorityProvider.notifier)
                .switchToService(effectiveService);
          }
        }

        // Only reset cycling state if this IS the primary service we're waiting for
        // If we're on a fallback service and it's playing, keep waiting for primary
        if (!_waitingForPrimaryResume ||
            _originalPrimaryService == effectiveService) {
          _resetCyclingState();
        }
      } else if (isFromDifferentService &&
          effectiveService == ServiceType.localSonos &&
          hasTrackInfo &&
          !currentServicePlaying) {
        // Sonos is paused with valid track info, and current service is also not playing
        // Only switch if current service is lower priority or unhealthy.

        // If current service is Spotify and it reports paused/stopped, treat that as global pause
        // and do not switch to Sonos just because Sonos has track info. Keep Sonos backend enabled
        // if already on for discovery to avoid config churn.
        if (currentService == ServiceType.directSpotify ||
            currentService == ServiceType.cloudSpotify) {
          return;
        }

        final priorityOrder = _config.priorityOrderOfServices;
        final idxCurrent =
            currentService == null ? -1 : priorityOrder.indexOf(currentService);
        final idxSonos = priorityOrder.indexOf(ServiceType.localSonos);
        final currentHigherPriority =
            idxCurrent >= 0 && idxSonos >= 0 && idxCurrent < idxSonos;
        final currentHealthy =
            currentService == null ? false : isServiceHealthy(currentService);

        if (currentHigherPriority && currentHealthy) {
          _disableSonosBackend();
        } else {
          ref
              .read(servicePriorityProvider.notifier)
              .switchToService(effectiveService);
        }
      } else if (_config.enableServiceCycling && !isFromDifferentService) {
        // Not playing - check if we should cycle based on status
        // Only handle cycling logic for the CURRENT service, not background services
        // Only start cycling if we're NOT already waiting for primary to resume
        if (!_waitingForPrimaryResume) {
          final status = playback?['status'] as String?;

          // Use status-based logic for Sonos (with track info awareness)
          if (effectiveService == ServiceType.localSonos) {
            _handleSonosPausedWithStatus(
              ServiceType.localSonos,
              status,
              hasTrackInfo: hasTrackInfo,
            );
          } else {
            _handleServicePaused(effectiveService);
          }
        }
      }

      // Update state/UI if:
      // 1. This is for the current active service, OR
      // 2. This service is playing, OR
      // 3. This service has valid track data and current service is not playing
      final shouldUpdateUI = !isFromDifferentService ||
          isPlaying ||
          (hasTrackInfo && !currentServicePlaying);

      if (shouldUpdateUI) {
        _processPayload(wsState.payload!, effectiveService);
      }
    }
  }

  void _processPayload(Map<String, dynamic> payload, ServiceType source) {
    // Extract data from payload
    final track = payload['track'] as Map<String, dynamic>?;
    final playback = payload['playback'] as Map<String, dynamic>?;
    final device = payload['device'] as Map<String, dynamic>?;
    final provider = payload['provider'] as String?;
    final isPlaying = playback?['is_playing'] as bool? ?? false;

    // Track last time we observed active playback for idle reset watchdog.
    if (isPlaying) {
      _lastPlayingTime = DateTime.now();
    }

    // Check if this is empty/stopped data
    // final isStopped = (playback?['status'] as String?) == 'stopped' ||
    //     (track?['title'] as String?)?.isEmpty == true;

    // Empty data is treated as "stopped" - NOT a fallback trigger
    // if (isStopped) {
    //   // Only log stopped/empty data on transition (not every poll)
    //   if (state.isPlaying) {
    //     _log('Received stopped/empty data from $source - music paused/stopped');
    //   }
    // }

    // Check if Spotify data is coming from a Speaker device (likely Sonos)
    // This helps handle cases where the Sonos server has wrong coordinator
    // by triggering Sonos re-discovery when we detect playback on a Speaker device
    if (provider == 'spotify' && device != null) {
      _checkForSpeakerDevice(device, isPlaying);
    }

    // If we received data from Sonos, reset the Speaker detection state
    // This means Sonos discovery was successful
    if (provider == 'sonos') {
      _resetSpeakerDetectionState();
    }

    // Update state with new data
    state = state.copyWith(
      isPlaying: isPlaying,
      track: track,
      playback: playback,
      device: device,
      provider: provider,
      activeService: source,
      isConnected: true,
      isLoading: false,
      clearError: true,
    );

    // Update last data time
    _lastDataTime = DateTime.now();

    // Cancel the activation timeout timer since we received data
    _timeoutTimer?.cancel();

    // Report success to priority manager
    ref.read(servicePriorityProvider.notifier).reportSuccess(source);

    // When a higher-priority service is actively playing with valid track data,
    // stop all lower-priority activity and polling.
    final priority = ref.read(servicePriorityProvider);
    final hasTrackInfo = _hasValidTrackInfo(track);
    final isCurrent = priority.currentService == source;
    if (isCurrent && isPlaying && hasTrackInfo) {
      ref
          .read(servicePriorityProvider.notifier)
          .quiesceLowerPriorityServices(source);
    }

    // If a higher-priority cloud/local service is active but not playing and has
    // no track info (idle/empty), pause direct Spotify retry activity to avoid
    // unnecessary calls while we wait out the stopped/idle window.
    if (isCurrent && !isPlaying && !hasTrackInfo && source.isCloudService) {
      ref.read(spotifyDirectProvider.notifier).stopPolling();
    }

    // If a cloud service was marked awaiting recovery, receiving any data means
    // the backend is responsive again. Clear awaiting-recovery so we can use it.
    final priorityState = ref.read(servicePriorityProvider);
    if (source.isCloudService &&
        priorityState.awaitingRecovery.contains(source)) {
      _log(
          'Data received from $source while awaiting recovery - marking healthy');

      final providerKey =
          source == ServiceType.localSonos ? 'sonos' : 'spotify';
      _serviceHealth[providerKey] = ServiceHealthState(
        provider: providerKey,
        status: HealthStatus.healthy,
        lastHealthyAt: DateTime.now(),
      );

      ref.read(servicePriorityProvider.notifier).onServiceRecovered(source);
      _syncUnhealthyServices();
    }
  }

  /// Check if Spotify is playing on a Speaker device (likely Sonos)
  /// and trigger Sonos re-discovery if needed
  void _checkForSpeakerDevice(Map<String, dynamic> device, bool isPlaying) {
    final deviceType = device['type'] as String?;
    final deviceName = device['name'] as String?;
    final priority = ref.read(servicePriorityProvider);
    final sonosEnabled =
        priority.enabledServices.contains(ServiceType.localSonos);

    // Only allow Speaker-triggered discovery when we're on a Spotify-driven path
    // (direct or cloud). If Sonos is the active service, skip to avoid loops.
    final currentService = priority.currentService;
    final sonosHigherThanCurrent = currentService != null &&
        _isHigherPriority(ServiceType.localSonos, currentService);
    final isSpotifyContext = currentService == null ||
        currentService == ServiceType.directSpotify ||
        currentService == ServiceType.cloudSpotify;
    if (!isSpotifyContext) {
      return;
    }

    // If direct Spotify is active and Sonos is higher priority, allow enabling Sonos
    // so the system can switch up to the higher-priority service when Speaker is detected.
    // Otherwise keep Sonos disabled to avoid loops.
    final allowDirectSpotifyDiscovery =
        currentService == ServiceType.directSpotify &&
            sonosEnabled &&
            sonosHigherThanCurrent;

    if (currentService == ServiceType.directSpotify &&
        !allowDirectSpotifyDiscovery) {
      _disableSonosBackend();
      _resetSpeakerDetectionState();
      return;
    }

    if (currentService == ServiceType.directSpotify &&
        allowDirectSpotifyDiscovery) {
      // _log('Speaker detected while on directSpotify - Sonos higher priority, enabling backend for discovery');
      _enableSonosBackendForSpeaker();
    }

    // Only process Speaker devices (Sonos groups appear as "Speaker" in Spotify API)
    if (deviceType != 'Speaker') {
      // Not a Speaker device - reset detection state if device changed
      if (_lastSpeakerDeviceName != null) {
        _resetSpeakerDetectionState();
      }
      return;
    }

    // Check if this is a new Speaker device or same device we already triggered for
    if (deviceName == _lastSpeakerDeviceName && _sonosDiscoveryTriggered) {
      // Already triggered discovery for this device, skip
      return;
    }

    // Check if Sonos is enabled in user settings
    if (!sonosEnabled) {
      // _log('Spotify playing on Speaker "$deviceName" but Sonos is disabled - skipping discovery');
      return;
    }

    // Only trigger if music is playing
    if (!isPlaying) {
      return;
    }

    // Trigger discovery when cloud Spotify is active, or when direct Spotify is active
    // but Sonos is higher priority (so we can switch up).
    final shouldTriggerDiscovery = currentService == null ||
        currentService == ServiceType.cloudSpotify ||
        (currentService == ServiceType.directSpotify &&
            allowDirectSpotifyDiscovery);

    if (shouldTriggerDiscovery) {
      _lastSpeakerDeviceName = deviceName;
      _sonosDiscoveryTriggered = true;

      // If we're about to switch to Sonos immediately, let the normal service
      // activation send the config to avoid duplicate configs from discovery.
      final willSwitchToSonos = currentService == ServiceType.cloudSpotify &&
          priority.isServiceAvailable(ServiceType.localSonos);

      // When directSpotify is active and we've already enabled Sonos on the
      // backend for speaker detection, avoid sending an extra discovery config.
      final skipDiscoveryBecauseBackendEnabled =
          currentService == ServiceType.directSpotify &&
              _sonosBackendEnabledForSpeaker;

      if (!willSwitchToSonos && !skipDiscoveryBecauseBackendEnabled) {
        _triggerSonosDiscovery();
        // } else if (skipDiscoveryBecauseBackendEnabled) {
        //   _log('Speaker detected while Sonos backend already enabled - skipping duplicate discovery config');
      }

      if (willSwitchToSonos) {
        ref
            .read(servicePriorityProvider.notifier)
            .switchToService(ServiceType.localSonos);
      }
    }
  }

  /// Reset the Speaker device detection state
  void _resetSpeakerDetectionState() {
    _lastSpeakerDeviceName = null;
    _sonosDiscoveryTriggered = false;
  }

  /// Trigger Sonos discovery by sending config with enabled.sonos=true
  void _triggerSonosDiscovery() {
    final ws = ref.read(eventsWsProvider.notifier);
    ws.triggerSonosDiscovery();
  }

  /// Enable Sonos on the backend while we are on direct Spotify so we can switch up
  /// to the higher-priority Sonos service when a Speaker device is detected.
  void _enableSonosBackendForSpeaker() {
    if (_sonosBackendEnabledForSpeaker) {
      return;
    }
    _sonosBackendEnabledForSpeaker = true;
    final ws = ref.read(eventsWsProvider.notifier);
    ws.sendConfigForService(
      ServiceType.directSpotify,
      keepSonosEnabled: true,
      keepSpotifyPollingForRecovery: false,
    );
  }

  /// Explicitly disable Sonos on the backend (keeps Spotify token request intact)
  void _disableSonosBackend() {
    _sonosBackendEnabledForSpeaker = false;
    final ws = ref.read(eventsWsProvider.notifier);
    ws.sendConfigForService(
      ServiceType.directSpotify,
      keepSonosEnabled: false,
      keepSpotifyPollingForRecovery: false,
    );
  }

  bool _isServerManagedService(ServiceType service) {
    // Server-managed paths are handled by backend polling/streaming.
    return service == ServiceType.localSonos ||
        service == ServiceType.cloudSpotify;
  }

  bool _isHigherPriority(ServiceType candidate, ServiceType reference) {
    final order = _config.priorityOrderOfServices;
    final idxCandidate = order.indexOf(candidate);
    final idxReference = order.indexOf(reference);
    if (idxCandidate < 0 || idxReference < 0) return false;
    return idxCandidate < idxReference;
  }

  bool _isLowerPriority(ServiceType candidate, ServiceType reference) {
    final order = _config.priorityOrderOfServices;
    final idxCandidate = order.indexOf(candidate);
    final idxReference = order.indexOf(reference);
    if (idxCandidate < 0 || idxReference < 0) return false;
    return idxCandidate > idxReference;
  }

  bool _shouldHoldGlobalPause(ServiceType? prevService,
      ServiceType? currentService, ServicePriorityState nextState) {
    if (prevService == null || currentService == null) return false;

    // Only guard when attempting to move down the priority order from direct
    // Spotify to cloud Spotify.
    final movingToLowerPriority = _isLowerPriority(currentService, prevService);
    final isDirectToCloud = prevService == ServiceType.directSpotify &&
        currentService == ServiceType.cloudSpotify;
    if (!movingToLowerPriority || !isDirectToCloud) return false;

    // Only hold if the previous service is not in a failing/cooldown state.
    final prevStatus = nextState.serviceStatuses[prevService];
    final prevHealthy = prevStatus == ServiceStatus.active ||
        prevStatus == ServiceStatus.standby;
    if (!prevHealthy) return false;

    // Treat Spotify paused/stopped as a global pause signal.
    final isGlobalPause = !state.isPlaying && state.provider == 'spotify';
    final stillOnPrevService = state.activeService == prevService;

    return isGlobalPause && stillOnPrevService;
  }

  /// Handle service status messages from WebSocket backend
  /// Supports both single status format and multi-status format (probe response)
  void _handleServiceStatus(Map<String, dynamic> data) {
    // Check if this is a multi-status response (from probe request)
    final statuses = data['statuses'] as List?;
    if (statuses != null) {
      // Handle each status in the array
      for (final status in statuses) {
        if (status is Map<String, dynamic>) {
          _handleSingleServiceStatus(status);
        }
      }
    } else {
      // Single status format (regular health update)
      _handleSingleServiceStatus(data);
    }
  }

  /// Handle a single service status update
  void _handleSingleServiceStatus(Map<String, dynamic> data) {
    final healthState = ServiceHealthState.fromMessage(data);
    final provider = healthState.provider;

    // _log('Service status: $provider = ${healthState.status.name}'
    //     '${healthState.errorCode != null ? ' (${healthState.errorCode!.name})' : ''}'
    //     '${healthState.message != null ? ' - ${healthState.message}' : ''}');

    // Store the health state
    final previousHealth = _serviceHealth[provider];
    _serviceHealth[provider] = healthState;

    // Determine the service type for this provider
    final serviceType = provider == 'sonos'
        ? ServiceType.localSonos
        : (provider == 'spotify'
            ? ServiceType.cloudSpotify
            : (provider == 'native_sonos'
                ? ServiceType.nativeLocalSonos
                : null));

    if (serviceType == null) {
      _log('Unknown provider: $provider');
      return;
    }

    // Check if this is a NEW unhealthy state (status changed from healthy to unhealthy)
    final wasHealthy =
        previousHealth == null || previousHealth.status.isHealthy;
    final isNowUnhealthy = !healthState.status.isHealthy;

    final currentService = ref.read(servicePriorityProvider).currentService;

    // If service is now unhealthy, mark awaiting-recovery for cloud services
    if (isNowUnhealthy && serviceType.isCloudService) {
      ref
          .read(servicePriorityProvider.notifier)
          .markAwaitingRecovery(serviceType);
    }

    // Handle based on status
    switch (healthState.status) {
      case HealthStatus.healthy:
        _onServiceRecovered(serviceType, healthState, previousHealth);
        break;

      case HealthStatus.degraded:
        // Degraded but usable - don't cycle, just log
        _log('$serviceType is degraded but usable');
        break;

      case HealthStatus.recovering:
      case HealthStatus.unavailable:
        // Only cycle if:
        // 1. This is NEW unhealthy state (was healthy before)
        // 2. Current service is the unhealthy one
        // 3. shouldFallback is true (for recovering) or always (for unavailable)
        final shouldCycle =
            wasHealthy && isNowUnhealthy && currentService == serviceType;

        if (shouldCycle) {
          if (healthState.status == HealthStatus.recovering &&
              !healthState.shouldFallback) {
            _log('$serviceType recovering but shouldFallback=false - staying');
          } else {
            _log(
                '$serviceType became ${healthState.status.name} (first time) - reporting error for thresholded fallback');
            // Let priority manager apply its error threshold (e.g., LOCAL_SONOS_FALLBACK_ERROR_THRESHOLD)
            // instead of immediate cycling on first error.
            ref.read(servicePriorityProvider.notifier).reportError(serviceType);
          }
        } else if (!wasHealthy && isNowUnhealthy) {
          // Still unhealthy. If this is the active service and shouldFallback
          // is true (or status is unavailable), keep incrementing the error
          // count so we eventually fall through to the next priority service.
          final shouldFallback =
              healthState.status == HealthStatus.unavailable ||
                  healthState.shouldFallback;

          if (currentService == serviceType && shouldFallback) {
            // _log('$serviceType still ${healthState.status.name} - reporting error toward fallback');
            ref.read(servicePriorityProvider.notifier).reportError(serviceType);
            // } else {
            //   _log('$serviceType still ${healthState.status.name} - staying on current fallback');
          }
        }

        // Handle auth error specially - no auto-retry
        if (healthState.errorCode?.requiresUserAction == true) {
          _log('$serviceType requires user action - no auto-retry');
        }
        break;
    }

    // Always sync unhealthy services to priority manager after health state changes
    _syncUnhealthyServices();
  }

  /// Called when a service recovers from an unhealthy state
  void _onServiceRecovered(
    ServiceType service,
    ServiceHealthState health,
    ServiceHealthState? previousHealth,
  ) {
    // Only process recovery if it was previously unhealthy
    if (previousHealth == null || previousHealth.status.isHealthy) {
      return;
    }

    _log('$service recovered with ${health.devicesCount} devices');

    // If we're currently on direct Spotify and a higher-priority cloud/local service
    // has recovered, stop direct polling so it doesn't keep retrying once we switch.
    final currentBeforeRecovery =
        ref.read(servicePriorityProvider).currentService;
    if (currentBeforeRecovery == ServiceType.directSpotify &&
        service.isCloudService) {
      ref.read(spotifyDirectProvider.notifier).stopPolling();
    }

    // Clear awaiting-recovery state and reset status in priority manager
    ref.read(servicePriorityProvider.notifier).onServiceRecovered(service);

    // If this service is higher priority than current, switch back to it
    final currentService = ref.read(servicePriorityProvider).currentService;
    if (currentService != null && currentService != service) {
      final serviceList = _config.priorityOrderOfServices;
      final currentPriority = serviceList.indexOf(currentService);
      final recoveredPriority = serviceList.indexOf(service);

      // Switch to recovered service if it's higher priority than current
      // (lower index = higher priority)
      if (recoveredPriority >= 0 &&
          (currentPriority < 0 || recoveredPriority < currentPriority)) {
        _log('Higher-priority service $service recovered - switching back');

        // Reset cycling state so the recovered service gets a fresh evaluation
        // This ensures that if it has no playback, it will cycle to the next service
        _resetCyclingState();

        // Stop any pending pause/cycle timers and retry timers from lower-priority services.
        _cancelPauseTimer();
        ref.read(servicePriorityProvider.notifier).stopRetryTimers();

        // Set original primary to the recovered service
        _originalPrimaryService = service;

        ref.read(servicePriorityProvider.notifier).switchToService(service);
      }
    }
  }

  /// Get the current health state for a service
  ServiceHealthState? getServiceHealth(ServiceType service) {
    final provider = switch (service) {
      ServiceType.localSonos => 'sonos',
      ServiceType.nativeLocalSonos => 'native_sonos',
      _ => 'spotify',
    };
    return _serviceHealth[provider];
  }

  /// Check if a service is healthy and usable
  bool isServiceHealthy(ServiceType service) {
    final health = getServiceHealth(service);
    return health == null || health.status.isHealthy;
  }

  /// Sync unhealthy services to the priority manager
  /// Call this after any health state change
  void _syncUnhealthyServices() {
    final unhealthyServices = <ServiceType>{};
    for (final entry in _serviceHealth.entries) {
      if (!entry.value.status.isHealthy) {
        final serviceType = entry.key == 'sonos'
            ? ServiceType.localSonos
            : (entry.key == 'native_sonos'
                ? ServiceType.nativeLocalSonos
                : (entry.key == 'spotify' ? ServiceType.cloudSpotify : null));
        if (serviceType != null) {
          unhealthyServices.add(serviceType);
        }
      }
    }
    ref
        .read(servicePriorityProvider.notifier)
        .updateUnhealthyServices(unhealthyServices);
  }

  /// Handle when a service reports paused/stopped - start timer to cycle
  /// Note: For Sonos, use _handleSonosPausedWithStatus instead for state-based handling
  void _handleServicePaused(ServiceType service) {
    // Spotify pause/stop implies global playback pause (track list spans Sonos devices),
    // so do not cycle to Sonos on this signal.
    if (service == ServiceType.directSpotify ||
        service == ServiceType.cloudSpotify) {
      // _log('$service paused/stopped - treating as global pause, not cycling');
      return;
    }

    // Skip if we already have a pause timer running for this service
    if (_pausedService == service && _servicePausedTimer != null) return;

    // Skip if this service has already been checked this cycle and found not playing
    // This prevents infinite loops when all services are paused/stopped
    if (_checkedNotPlaying.contains(service)) {
      return;
    }

    // Cancel any existing timer for a different service
    _cancelPauseTimer();

    // Get the pause wait duration for this service (for Spotify services)
    final waitSec = _config.spotifyPausedWaitSec;

    // 0 means disabled - don't cycle for this service
    if (waitSec <= 0) {
      _log('$service not playing - cycling disabled (waitSec=0)');
      return;
    }

    _log('$service not playing - waiting ${waitSec}s before cycling');

    _pausedService = service;
    _servicePausedTimer = Timer(Duration(seconds: waitSec), () {
      _onServicePauseTimerExpired(service);
    });
  }

  /// Check if track info is present and valid (not empty)
  bool _hasValidTrackInfo(Map<String, dynamic>? track) {
    if (track == null) return false;
    final title = track['title'] as String?;
    return title != null && title.isNotEmpty;
  }

  /// Handle Sonos pause/stop with status-based wait times
  /// Different wait times based on transport state:
  /// - paused (with track): usually 0 (disabled) - user likely to resume
  /// - paused (no track): use idle wait time - user may have switched away
  /// - stopped: longer wait (e.g., 30s) - queue might have ended
  /// - idle/no_media: quick switch (e.g., 3s) - nothing to play
  ///
  /// NOTE: Even if Sonos has never played this session, we still cycle
  /// (with idle wait time) to discover if other services are playing.
  void _handleSonosPausedWithStatus(
    ServiceType service,
    String? status, {
    bool hasTrackInfo = true,
  }) {
    // Skip if we already have a pause timer running for Sonos
    if (_pausedService == service && _servicePausedTimer != null) {
      return;
    }

    // Skip if Sonos has already been checked this cycle and found not playing
    // This prevents infinite loops when all services are paused/stopped
    if (_checkedNotPlaying.contains(service)) {
      return;
    }

    // Cancel any existing timer
    _cancelPauseTimer();

    // Determine wait time based on Sonos status and track info
    final int waitSec;
    final pausedWait = service == ServiceType.nativeLocalSonos
        ? _config.nativeLocalSonosPausedWaitSec
        : _config.localSonosPausedWaitSec;
    final stoppedWait = service == ServiceType.nativeLocalSonos
        ? _config.nativeLocalSonosStoppedWaitSec
        : _config.localSonosStoppedWaitSec;
    final idleWait = service == ServiceType.nativeLocalSonos
        ? _config.nativeLocalSonosIdleWaitSec
        : _config.localSonosIdleWaitSec;
    final normalizedStatus = (status ?? 'idle').toLowerCase();

    // "paused" but no track info means user has switched away from Sonos
    // This should ALWAYS use the short idle wait time - the user has actively
    // switched to another device/app, so we should check other services quickly
    if (normalizedStatus == 'paused' && !hasTrackInfo) {
      waitSec = idleWait;
    } else {
      switch (normalizedStatus) {
        case 'paused':
          // True pause with track info - user may resume
          waitSec = pausedWait;
          break;
        case 'stopped':
          waitSec = stoppedWait;
          break;
        case 'transitioning':
        case 'buffering':
          // Don't cycle during transitioning/buffering - temporary state
          return;
        case 'playing':
          // Should not reach here, but just in case
          return;
        default:
          // idle, no_media, or unknown - use idle wait time
          waitSec = idleWait;
      }
    }

    // 0 means disabled - don't cycle for this status
    if (waitSec <= 0) {
      return;
    }

    _pausedService = service;
    _servicePausedTimer = Timer(Duration(seconds: waitSec), () {
      _onServicePauseTimerExpired(service);
    });
  }

  /// Called when pause timer expires - try next service in priority
  void _onServicePauseTimerExpired(ServiceType service) {
    _servicePausedTimer = null;
    _pausedService = null;

    // Mark this service as checked
    _checkedNotPlaying.add(service);

    // If this is a Spotify service, also mark the other Spotify service as checked
    // (they use the same account, so if one isn't playing, neither is the other)
    if (service == ServiceType.directSpotify) {
      _checkedNotPlaying.add(ServiceType.cloudSpotify);
      _log('Also marking cloudSpotify as checked (same account)');
    } else if (service == ServiceType.cloudSpotify) {
      _checkedNotPlaying.add(ServiceType.directSpotify);
      _log('Also marking directSpotify as checked (same account)');
    }

    // Remember the original primary service if not set
    // final primaryService =
    //     _originalPrimaryService ??= _getHighestPriorityEnabledService();
    // if (primaryService != null) {
    //   _log('Remembering primary service: $primaryService');
    // }

    // Find next service to try
    final nextService = _getNextServiceToTry();

    if (nextService != null) {
      _waitingForPrimaryResume = true;

      // switchToService will trigger _handleServicePriorityChange which calls
      // _activateService -> sendConfigForService, so no need to send config here
      ref.read(servicePriorityProvider.notifier).switchToService(nextService);
    } else {
      // All services checked, none playing
      _log('All services checked - none playing');
      _startCycleResetTimer();

      // Stay on or switch to first available (not unhealthy) service
      // This ensures we don't switch to an unhealthy service that can't provide data
      final bestService = _getHighestPriorityAvailableService();
      if (bestService != null) {
        final current = ref.read(servicePriorityProvider).currentService;
        if (current != bestService) {
          _log('Switching to best available service: $bestService');
          ref
              .read(servicePriorityProvider.notifier)
              .switchToService(bestService);
        }
      } else {
        // No available services - keep current or clear
        _log('No available services after cycling');
      }

      // Reset waiting state since we've exhausted options
      _waitingForPrimaryResume = false;
      _originalPrimaryService = null;
    }
  }

  /// Get the next service to try (respecting priority, skipping checked services)
  ServiceType? _getNextServiceToTry() {
    final priority = ref.read(servicePriorityProvider);

    for (final service in _config.priorityOrderOfServices) {
      // Skip if not enabled
      if (!priority.enabledServices.contains(service)) continue;

      // Skip services that have already failed and are under recovery/probing;
      // the recovery loop will promote them when healthy. This avoids cycling
      // back to a failed service and resetting state unnecessarily.
      final inRecovery = priority.recoveryStates.containsKey(service);
      // Allow cycling to a failing service so we can advance when Sonos is paused
      // with no track; still skip if a dedicated recovery probe is already running.
      if (inRecovery) continue;

      // Skip if already checked this cycle
      if (_checkedNotPlaying.contains(service)) continue;

      // Skip if not available (in cooldown, etc.)
      if (!priority.isServiceAvailable(service)) continue;

      return service;
    }

    return null;
  }

  /// Get highest priority enabled AND available service
  /// (skips unhealthy services)
  ServiceType? _getHighestPriorityAvailableService() {
    final priority = ref.read(servicePriorityProvider);

    for (final service in _config.priorityOrderOfServices) {
      if (priority.enabledServices.contains(service) &&
          priority.isServiceAvailable(service)) {
        return service;
      }
    }

    return null;
  }

  /// Return the highest-priority Sonos service (native preferred) that is
  /// present in the configured priority list and currently enabled. If the
  /// list omits Sonos entirely, fall back to the first enabled Sonos variant
  /// (nativeLocalSonos preferred over localSonos).
  ServiceType? _preferredSonosService(ServicePriorityState priority) {
    const sonosCandidates = [
      ServiceType.nativeLocalSonos,
      ServiceType.localSonos,
    ];

    // Respect explicit priority order first
    for (final service in _config.priorityOrderOfServices) {
      if (sonosCandidates.contains(service) &&
          priority.enabledServices.contains(service)) {
        return service;
      }
    }

    // Fallback: choose the first enabled Sonos variant (native preferred)
    for (final candidate in sonosCandidates) {
      if (priority.enabledServices.contains(candidate)) {
        return candidate;
      }
    }

    return null;
  }

  /// Called when the primary service we were waiting for resumes
  void _handlePrimaryServiceResumed() {
    final primaryService = _originalPrimaryService;
    _log('Primary service resumed - switching back to $primaryService');

    _cancelPauseTimer();
    _resetCyclingState();

    if (primaryService != null) {
      ref
          .read(servicePriorityProvider.notifier)
          .switchToService(primaryService);
    }
  }

  /// Start the cycle reset timer
  void _startCycleResetTimer() {
    _cycleResetTimer?.cancel();

    final resetSec = _config.serviceCycleResetSec;
    _log('Starting cycle reset timer (${resetSec}s)');

    _cycleResetTimer = Timer(Duration(seconds: resetSec), () {
      _log('Cycle reset timer expired - clearing checked services');
      _checkedNotPlaying.clear();
      _cycleResetTimer = null;
    });
  }

  /// Cancel the pause timer
  void _cancelPauseTimer() {
    _servicePausedTimer?.cancel();
    _servicePausedTimer = null;
    _pausedService = null;
  }

  /// Reset all cycling state (called when any service starts playing)
  void _resetCyclingState() {
    _checkedNotPlaying.clear();
    _cycleResetTimer?.cancel();
    _cycleResetTimer = null;
    _waitingForPrimaryResume = false;
    _originalPrimaryService = null;
  }

  void _resetTimeoutTimer() {
    _timeoutTimer?.cancel();

    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;
    if (currentService == null) return;

    // Get fallback config for this service type
    final fallbackConfig = _config.getFallbackConfig(currentService);

    // Only set timeout if timeoutSec > 0 (disabled for event-driven services like Sonos)
    if (fallbackConfig.timeoutSec <= 0) return;

    _timeoutTimer = Timer(Duration(seconds: fallbackConfig.timeoutSec), () {
      ref.read(servicePriorityProvider.notifier).reportTimeout(currentService);
    });
  }

  void _startDataTimeoutWatcher() {
    // Check every 5 seconds if we're receiving data
    _dataWatchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final priority = ref.read(servicePriorityProvider);
      final currentService = priority.currentService;
      if (currentService == null) return;

      // Skip timeout check for cloud services - they're event-driven from server
      // and the WebSocket connection itself handles disconnection detection.
      // The server uses 304 Not Modified when data hasn't changed, which doesn't
      // send new data to client. This isn't a timeout condition, just no changes.
      if (currentService.isCloudService) return;

      // Get fallback config for this service type
      final fallbackConfig = _config.getFallbackConfig(currentService);

      // Only check timeout if timeoutSec > 0 (disabled for event-driven services like Sonos)
      if (fallbackConfig.timeoutSec <= 0) return;

      // Check if we haven't received data for too long
      if (_lastDataTime != null) {
        final elapsed = DateTime.now().difference(_lastDataTime!).inSeconds;
        if (elapsed > fallbackConfig.timeoutSec) {
          ref
              .read(servicePriorityProvider.notifier)
              .reportTimeout(currentService);
          _lastDataTime = DateTime.now(); // Reset to prevent repeated triggers
        }
      }
    });
  }

  void _startIdleResetWatcher() {
    _idleResetTimer?.cancel();

    final intervalSec = _config.serviceIdleCycleResetSec;
    final idleThresholdSec = _config.serviceIdleTimeSec;

    // Disable when interval <= 0 or threshold <= 0
    if (intervalSec <= 0 || idleThresholdSec <= 0) {
      return;
    }

    _log(
        'Starting idle reset watcher (interval=${intervalSec}s, threshold=${idleThresholdSec}s)');

    _idleResetTimer = Timer.periodic(
      Duration(seconds: intervalSec),
      (_) => _checkIdleReset(idleThresholdSec),
    );
  }

  void _checkIdleReset(int idleThresholdSec) {
    // If currently playing, refresh last-playing marker and skip
    // if (state.isPlaying) {
    //   _log('Idle check: currently playing - skip');
    //   return;
    // }

    final lastPlay = _lastPlayingTime ?? DateTime.now();
    final idleForSec = DateTime.now().difference(lastPlay).inSeconds;

    // Avoid repeated resets in rapid succession
    if (_lastIdleResetAt != null) {
      final sinceReset = DateTime.now().difference(_lastIdleResetAt!).inSeconds;
      if (sinceReset < idleThresholdSec) {
        _log(
            'Idle check: skip (recent reset ${sinceReset}s ago < threshold=${idleThresholdSec}s)');
        return;
      }
    }

    if (idleForSec >= idleThresholdSec) {
      _log(
          'Idle reset: no playback for ${idleForSec}s (threshold=${idleThresholdSec}s) - resetting services');
      _lastIdleResetAt = DateTime.now();
      reset();
      // } else {
      //   _log(
      //       'Idle check: idle ${idleForSec}s < threshold=${idleThresholdSec}s - no reset');
    }
  }

  /// Called when user settings change (e.g., from settings page)
  void updateServicesEnabled({
    required bool spotifyEnabled,
    required bool sonosEnabled,
  }) {
    _log('Services updated: spotify=$spotifyEnabled, sonos=$sonosEnabled');

    // If Spotify is being disabled, immediately stop direct polling
    // This ensures polling stops even if service switching hasn't occurred yet
    if (!spotifyEnabled) {
      _log('Spotify disabled - stopping direct polling');
      ref.read(spotifyDirectProvider.notifier).stopPolling();
    }

    // Collect unhealthy services so we don't auto-switch to them
    final unhealthyServices = <ServiceType>{};
    for (final entry in _serviceHealth.entries) {
      if (!entry.value.status.isHealthy) {
        final serviceType = entry.key == 'sonos'
            ? ServiceType.localSonos
            : (entry.key == 'native_sonos'
                ? ServiceType.nativeLocalSonos
                : (entry.key == 'spotify' ? ServiceType.cloudSpotify : null));
        if (serviceType != null) {
          unhealthyServices.add(serviceType);
        }
      }
    }
    _log('Unhealthy services: $unhealthyServices');

    // Update priority manager's unhealthy services state for use in fallback decisions
    ref
        .read(servicePriorityProvider.notifier)
        .updateUnhealthyServices(unhealthyServices);

    // Remember which services were enabled before the update
    final previousEnabledServices =
        ref.read(servicePriorityProvider).enabledServices.toSet();
    final previousActiveService =
        ref.read(servicePriorityProvider).currentService;

    ref.read(servicePriorityProvider.notifier).updateEnabledServices(
          spotifyEnabled: spotifyEnabled,
          sonosEnabled: sonosEnabled,
          nativeSonosSupported: _nativeSonosSupported,
          unhealthyServices: unhealthyServices,
        );

    // Re-evaluate active service - force switch if current is no longer enabled
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;
    final newEnabledServices = priority.enabledServices.toSet();

    // If Sonos was just enabled, proactively activate the highest-priority
    // Sonos variant present in the priority list (nativeLocalSonos preferred
    // by list order). If the list omits Sonos entirely, fall back to the first
    // enabled Sonos variant. Do this before evaluating generic switches so the
    // Sonos bridge starts immediately when toggled on.
    final sonosJustEnabled =
        (!previousEnabledServices.contains(ServiceType.nativeLocalSonos) &&
                newEnabledServices.contains(ServiceType.nativeLocalSonos)) ||
            (!previousEnabledServices.contains(ServiceType.localSonos) &&
                newEnabledServices.contains(ServiceType.localSonos));

    if (sonosJustEnabled) {
      final preferredSonos = _preferredSonosService(priority);
      if (preferredSonos != null) {
        final shouldSwitchToSonos = currentService == null ||
            _isHigherPriority(preferredSonos, currentService);
        if (shouldSwitchToSonos) {
          _log('Sonos enabled; activating $preferredSonos');
          ref
              .read(servicePriorityProvider.notifier)
              .activateService(preferredSonos);
          return; // Listener will handle activation/config
        }
      }
    }

    // Detect if services changed and whether a switch occurred
    final servicesChanged = previousEnabledServices != newEnabledServices;
    final switchOccurred = previousActiveService != currentService;

    // If a switch already occurred (handled by listener via _activateService),
    // we usually don't need to do anything here - the listener already sent config.
    // However, if the switch resulted in no current service (e.g., disabling
    // the only active service), we still need to push user-settings config so
    // the server stops polling/streaming.
    if (switchOccurred) {
      if (currentService == null) {
        _log(
            'Service switch cleared current service; sending user settings config');
        ref.read(eventsWsProvider.notifier).sendConfigForUserSettings();
      } else {
        _log('Service switch already handled by listener');
      }
      return;
    }

    if (currentService == null) {
      // No current service and no switch occurred - try to activate first available
      final newActiveService =
          ref.read(servicePriorityProvider.notifier).activateFirstAvailable();

      // If still no service (shouldn't normally happen since no switch occurred
      // means services didn't change in a way that affects current), log it
      if (newActiveService == null && newEnabledServices.isEmpty) {
        _log('No services to activate');
      }
    } else if (!priority.enabledServices.contains(currentService)) {
      // Current service is disabled but no switch occurred (shouldn't happen)
      _log(
          'Current service $currentService is disabled but no switch - forcing');
      ref.read(servicePriorityProvider.notifier).activateFirstAvailable();
    } else {
      // Current service is still enabled

      // If services changed but no switch occurred, we still need to send config
      // to the server so it knows to stop disabled services. Use user-settings
      // config to reflect the full enabled set and avoid multiple per-service
      // configs when toggling services without a switch.
      if (servicesChanged) {
        final newlyEnabledServices =
            newEnabledServices.difference(previousEnabledServices);
        final newlyDisabledServices =
            previousEnabledServices.difference(newEnabledServices);
        // Consider only server-managed services (backend-polling). If the only
        // changes are additions of lower-priority server-managed services while
        // a higher-priority service remains active, suppress sending config to
        // avoid enabling lower-tier polling (e.g., enabling Spotify while native
        // Sonos is active).
        final serverAdds =
            newlyEnabledServices.where(_isServerManagedService).toSet();
        final serverRemovals =
            newlyDisabledServices.where(_isServerManagedService).toSet();

        final suppressForLowerServerAdds = serverRemovals.isEmpty &&
            serverAdds.isNotEmpty &&
            serverAdds.every((s) => _isLowerPriority(s, currentService));

        if (suppressForLowerServerAdds) {
          _log(
              'Services changed without switch (lower-priority server additions only); suppressing user settings config');
        } else {
          _log(
              'Services changed without switch - sending user settings config');
          ref.read(eventsWsProvider.notifier).sendConfigForUserSettings();
        }
      }

      // Check if we should re-evaluate cycling
      // This handles the case where:
      // 1. Current service was checked and found not playing
      // 2. User enables new services
      // 3. We should check if the newly enabled services are playing
      final newlyEnabledServices =
          newEnabledServices.difference(previousEnabledServices);

      if (newlyEnabledServices.isNotEmpty &&
          _checkedNotPlaying.contains(currentService)) {
        _log(
            'New services enabled while current service not playing: $newlyEnabledServices');

        // Clear the checked set to allow re-evaluation
        // but keep the current service as "checked" since we know it's not playing
        _checkedNotPlaying.clear();
        _checkedNotPlaying.add(currentService);

        // Cancel cycle reset timer since we're re-evaluating now
        _cycleResetTimer?.cancel();
        _cycleResetTimer = null;

        // Try to find a playing service among the newly enabled ones
        final nextService = _getNextServiceToTry();
        if (nextService != null) {
          _log('Cycling to newly enabled service: $nextService');
          _waitingForPrimaryResume = true;
          _originalPrimaryService ??= currentService;

          // switchToService will trigger _handleServicePriorityChange which calls
          // _activateService -> sendConfigForService, so no need to send config here
          ref
              .read(servicePriorityProvider.notifier)
              .switchToService(nextService);
        } else {
          _log('No new services available to try');
          // Restart the cycle reset timer
          _startCycleResetTimer();
        }
      }
    }
  }

  /// Manually switch to a specific service (for debugging/testing)
  void switchToService(ServiceType service) {
    _log('Manual switch to $service');
    ref.read(servicePriorityProvider.notifier).activateService(service);
  }

  /// Force reconnect/restart the current service
  /// Called when app resumes from background after being idle
  void reconnect() {
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    _log('Reconnecting current service: $currentService');

    // Cancel any existing pause timer since it may not have fired while app was suspended
    // This allows fresh cycling evaluation when new data arrives
    _cancelPauseTimer();

    if (currentService != null) {
      _activateService(currentService);
    }
  }

  /// Reset everything and start fresh
  void reset() {
    _log('Reset requested');

    // Suppress priority change reactions while we tear down and restart
    _suppressPriorityChanges = true;

    _timeoutTimer?.cancel();
    _dataWatchTimer?.cancel();
    _cancelPauseTimer();
    _cycleResetTimer?.cancel();
    _idleResetTimer?.cancel();
    _lastDataTime = null;
    _lastPlayingTime = null;
    _lastIdleResetAt = null;
    _initialized = false;

    // Reset cycling state
    _resetCyclingState();
    _lastIsPlaying.clear();

    // Clear service health tracking
    _serviceHealth.clear();

    // Reset internal state without dropping the WebSocket connection.
    ref.read(eventsWsProvider.notifier).resetSessionStateForColdRestart();
    ref.read(servicePriorityProvider.notifier).reset();
    ref.read(spotifyDirectProvider.notifier).stopPolling();
    ref.read(nativeSonosProvider.notifier).stop();

    state = const UnifiedPlaybackState(isLoading: true);

    // Re-initialize
    Future.microtask(() => _initialize());
  }

  /// Stop all services and timers (called on logout)
  void _stopAllServices() {
    _log('Stopping all services');

    // Cancel all timers
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _dataWatchTimer?.cancel();
    _dataWatchTimer = null;
    _cancelPauseTimer();
    _cycleResetTimer?.cancel();
    _cycleResetTimer = null;
    _idleResetTimer?.cancel();
    _idleResetTimer = null;

    // Reset state
    _lastDataTime = null;
    _lastPlayingTime = null;
    _lastIdleResetAt = null;
    _initialized = false;
    _resetCyclingState();
    _lastIsPlaying.clear();

    // Clear service health tracking
    _serviceHealth.clear();

    // Stop services
    ref.read(servicePriorityProvider.notifier).reset();
    ref.read(spotifyDirectProvider.notifier).stopPolling();
    ref.read(nativeSonosProvider.notifier).stop();
    ref.read(eventsWsProvider.notifier).disconnectOnLogout();

    // Clear playback state
    state = const UnifiedPlaybackState();
  }
}

/// Provider for the service orchestrator
final serviceOrchestratorProvider =
    NotifierProvider<ServiceOrchestrator, UnifiedPlaybackState>(() {
  return ServiceOrchestrator();
});

/// Convenience provider to get just the active service type
final activeServiceProvider = Provider<ServiceType?>((ref) {
  return ref.watch(servicePriorityProvider).currentService;
});

/// Convenience provider to check if we're using direct Spotify
final isDirectSpotifyActiveProvider = Provider<bool>((ref) {
  return ref.watch(activeServiceProvider) == ServiceType.directSpotify;
});

/// Convenience provider to check if we're using cloud Spotify
final isCloudSpotifyActiveProvider = Provider<bool>((ref) {
  return ref.watch(activeServiceProvider) == ServiceType.cloudSpotify;
});

/// Convenience provider to check if we're using local Sonos
final isLocalSonosActiveProvider = Provider<bool>((ref) {
  return ref.watch(activeServiceProvider) == ServiceType.localSonos;
});

/// Convenience provider to check if we're using native/local (on-device) Sonos
final isNativeLocalSonosActiveProvider = Provider<bool>((ref) {
  return ref.watch(activeServiceProvider) == ServiceType.nativeLocalSonos;
});

/// Convenience provider to check if we're using any cloud service
final isCloudServiceActiveProvider = Provider<bool>((ref) {
  final service = ref.watch(activeServiceProvider);
  return service?.isCloudService ?? false;
});
