import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/events_ws_service.dart';
import 'package:media_display/src/services/service_health.dart';
import 'package:media_display/src/services/service_priority_manager.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/spotify_direct_service.dart';
import 'package:media_display/src/services/user_service.dart';

/// Timestamped debug print for correlation with server logs
void _log(String message) {
  final now = DateTime.now();
  final mo = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  final h = now.hour.toString().padLeft(2, '0');
  final m = now.minute.toString().padLeft(2, '0');
  final s = now.second.toString().padLeft(2, '0');
  final ms = now.millisecond.toString().padLeft(3, '0');
  debugPrint('[$mo-$d $h:$m:$s.$ms] $message');
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
  DateTime? _lastDataTime;

  bool _initialized = false;

  // Service cycling state
  ServiceType? _pausedService;
  final Set<ServiceType> _checkedNotPlaying = {};
  bool _waitingForPrimaryResume = false;
  ServiceType? _originalPrimaryService;

  // Track last playing state per service
  final Map<ServiceType, bool> _lastIsPlaying = {};

  // Service health tracking
  final Map<String, ServiceHealthState> _serviceHealth = {};

  EnvConfig get _config => ref.read(envConfigProvider);

  @override
  UnifiedPlaybackState build() {
    ref.onDispose(() {
      _timeoutTimer?.cancel();
      _dataWatchTimer?.cancel();
      _servicePausedTimer?.cancel();
      _cycleResetTimer?.cancel();
    });

    // Initialize asynchronously
    Future.microtask(() => _initialize());

    return const UnifiedPlaybackState(isLoading: true);
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Set up service status callback to receive health updates from WebSocket
    ref.read(eventsWsProvider.notifier).onServiceStatus = _handleServiceStatus;

    // Load user settings to determine which services are enabled
    await _loadServicesSettings();

    // Start listening to service changes
    _startServiceWatchers();

    // Activate the first available service
    ref.read(servicePriorityProvider.notifier).activateFirstAvailable();
  }

  Future<void> _loadServicesSettings() async {
    try {
      final user = await ref.read(userServiceProvider).fetchMe();
      final userId = user['id']?.toString() ?? '';
      if (userId.isEmpty) return;

      final settings =
          await ref.read(settingsServiceProvider).fetchSettingsForUser(userId);
      final spotifyEnabled = settings['spotify_enabled'] == true;
      final sonosEnabled = settings['sonos_enabled'] == true;

      _log(
          '[Orchestrator] Settings loaded: spotify=$spotifyEnabled, sonos=$sonosEnabled');

      // Update service priority with enabled services
      ref.read(servicePriorityProvider.notifier).updateEnabledServices(
            spotifyEnabled: spotifyEnabled,
            sonosEnabled: sonosEnabled,
          );
    } catch (e) {
      _log('[Orchestrator] Failed to load settings: $e');
    }
  }

  void _startServiceWatchers() {
    // Watch auth state changes to stop everything on logout
    ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (prev?.isAuthenticated == true && !next.isAuthenticated) {
        _log('[Orchestrator] User logged out - stopping all services');
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

    // Watch WebSocket/cloud service
    ref.listen<NowPlayingState>(eventsWsProvider, (prev, next) {
      _handleCloudServiceChange(next);
    });

    // Start data timeout watcher
    _startDataTimeoutWatcher();
  }

  void _handleServicePriorityChange(
      ServicePriorityState? prev, ServicePriorityState next) {
    final currentService = next.currentService;
    final prevService = prev?.currentService;

    if (currentService != prevService) {
      _log(
          '[Orchestrator] Active service changed: $prevService -> $currentService');

      // Check if this is a switch to a higher-priority service (not a fallback due to cycling)
      // If so, reset cycling state to allow fresh evaluation of the new service
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
          }
        }

        if (shouldResetCycling) {
          _log(
              '[Orchestrator] Switching to higher-priority service - resetting cycling state');
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
      _activateService(currentService);
    }
  }

  void _activateService(ServiceType? service) {
    if (service == null) {
      _log('[Orchestrator] No service to activate');
      return;
    }

    _log('[Orchestrator] Activating service: $service');

    if (service.isDirectPolling) {
      _activateDirectSpotify();
    } else {
      // cloud_spotify or local_sonos
      _activateCloudService(service);
    }
  }

  void _activateDirectSpotify() {
    _log('[Orchestrator] Activating direct Spotify polling');

    // Stop any direct polling first (in case switching from another mode)
    // Start direct polling
    ref.read(spotifyDirectProvider.notifier).startDirectPolling();

    // Send WebSocket config to tell backend not to poll
    // (we're polling directly from client)
    // Keep sonos enabled if we're waiting for it to resume
    final keepSonos = _waitingForPrimaryResume &&
        _originalPrimaryService == ServiceType.localSonos;
    ref.read(eventsWsProvider.notifier).sendConfigForService(
          ServiceType.directSpotify,
          keepSonosEnabled: keepSonos,
        );

    // Reset timeout timer
    _resetTimeoutTimer();
  }

  void _activateCloudService(ServiceType service) {
    _log('[Orchestrator] Activating cloud service: $service');

    // Stop direct polling if it was running
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    // Connect/reconnect WebSocket and send config for this service
    // Keep sonos enabled if we're waiting for it to resume
    final keepSonos = _waitingForPrimaryResume &&
        _originalPrimaryService == ServiceType.localSonos;
    ref.read(eventsWsProvider.notifier).connect();
    ref.read(eventsWsProvider.notifier).sendConfigForService(
          service,
          keepSonosEnabled: keepSonos,
        );

    // Reset timeout timer
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
        _log('[Orchestrator] Primary service directSpotify resumed playing!');
        _handlePrimaryServiceResumed();
        return;
      }
    }

    // Only process if direct_spotify is active
    if (priority.currentService != ServiceType.directSpotify) return;

    // Check for errors
    if (spotifyState.error != null) {
      // Check if it's a 401 error (handled separately - triggers token refresh, not fallback)
      if (spotifyState.error!.contains('401') ||
          spotifyState.error!.contains('Unauthorized')) {
        _log('[Orchestrator] Direct Spotify 401 - token refresh triggered');
        return; // Don't trigger fallback for auth errors
      }

      // Report error to priority manager
      ref
          .read(servicePriorityProvider.notifier)
          .reportError(ServiceType.directSpotify);
    }

    // Check for fallback mode
    if (spotifyState.mode == SpotifyPollingMode.fallback ||
        spotifyState.mode == SpotifyPollingMode.offline) {
      _log(
          '[Orchestrator] Direct Spotify in fallback/offline mode - triggering service fallback');
      ref
          .read(servicePriorityProvider.notifier)
          .reportError(ServiceType.directSpotify);
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
            _log('[Orchestrator] Spotify stopped playing');
          }
          _handleServicePaused(ServiceType.directSpotify);
        }
      }

      _processPayload(spotifyState.payload!, ServiceType.directSpotify);
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
        _log('[Orchestrator] Primary service $dataSource resumed playing!');
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
        _log('[Orchestrator] Cloud service disconnected: ${wsState.error}');
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

        // If Sonos starts playing but we're on a different service, switch to Sonos
        if (isFromDifferentService &&
            effectiveService == ServiceType.localSonos) {
          _log(
              '[Orchestrator] Sonos started playing while on $currentService - switching to Sonos');
          ref
              .read(servicePriorityProvider.notifier)
              .switchToService(effectiveService);
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
        // This means user switched their playback device to Sonos (even while paused)
        // Switch to show Sonos data
        _log(
            '[Orchestrator] Sonos has track data while $currentService is not playing - switching to Sonos');
        ref
            .read(servicePriorityProvider.notifier)
            .switchToService(effectiveService);
      } else if (_config.enableServiceCycling && !isFromDifferentService) {
        // Not playing - check if we should cycle based on status
        // Only handle cycling logic for the CURRENT service, not background services
        // Only start cycling if we're NOT already waiting for primary to resume
        if (!_waitingForPrimaryResume) {
          final status = playback?['status'] as String?;

          // Use status-based logic for Sonos (with track info awareness)
          if (effectiveService == ServiceType.localSonos) {
            _handleSonosPausedWithStatus(status, hasTrackInfo: hasTrackInfo);
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

    // Check if this is empty/stopped data
    final isStopped = (playback?['status'] as String?) == 'stopped' ||
        (track?['title'] as String?)?.isEmpty == true;

    // Empty data is treated as "stopped" - NOT a fallback trigger
    if (isStopped) {
      // Only log stopped/empty data on transition (not every poll)
      if (state.isPlaying) {
        _log(
            '[Orchestrator] Received stopped/empty data from $source - music paused/stopped');
      }
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
  }

  /// Handle service status messages from WebSocket backend
  void _handleServiceStatus(Map<String, dynamic> data) {
    final healthState = ServiceHealthState.fromMessage(data);
    final provider = healthState.provider;

    _log('[Orchestrator] Service status: $provider = ${healthState.status.name}'
        '${healthState.errorCode != null ? ' (${healthState.errorCode!.name})' : ''}'
        '${healthState.message != null ? ' - ${healthState.message}' : ''}');

    // Store the health state
    final previousHealth = _serviceHealth[provider];
    _serviceHealth[provider] = healthState;

    // Determine the service type for this provider
    final serviceType = provider == 'sonos'
        ? ServiceType.localSonos
        : (provider == 'spotify' ? ServiceType.cloudSpotify : null);

    if (serviceType == null) {
      _log('[Orchestrator] Unknown provider: $provider');
      return;
    }

    final currentService = ref.read(servicePriorityProvider).currentService;

    // Check if this is a NEW unhealthy state (status changed from healthy to unhealthy)
    final wasHealthy =
        previousHealth == null || previousHealth.status.isHealthy;
    final isNowUnhealthy = !healthState.status.isHealthy;

    // Handle based on status
    switch (healthState.status) {
      case HealthStatus.healthy:
        _onServiceRecovered(serviceType, healthState, previousHealth);
        break;

      case HealthStatus.degraded:
        // Degraded but usable - don't cycle, just log
        _log('[Orchestrator] $serviceType is degraded but usable');
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
            _log(
                '[Orchestrator] $serviceType recovering but shouldFallback=false - staying');
          } else {
            _log(
                '[Orchestrator] $serviceType became ${healthState.status.name} (first time) - cycling to fallback');
            _cycleToNextService(serviceType);
          }
        } else if (!wasHealthy && isNowUnhealthy) {
          // Already unhealthy - don't switch again, stay on fallback
          _log(
              '[Orchestrator] $serviceType still ${healthState.status.name} - staying on current fallback');
        }

        // Handle auth error specially - no auto-retry
        if (healthState.errorCode?.requiresUserAction == true) {
          _log(
              '[Orchestrator] $serviceType requires user action - no auto-retry');
        }
        break;
    }
  }

  /// Called when a service recovers from an unhealthy state
  void _onServiceRecovered(
    ServiceType service,
    ServiceHealthState health,
    ServiceHealthState? previousHealth,
  ) {
    // Only log recovery if it was previously unhealthy
    if (previousHealth != null && !previousHealth.status.isHealthy) {
      _log(
          '[Orchestrator] $service recovered with ${health.devicesCount} devices');

      // If this service is higher priority than current and was our original primary,
      // switch back to it
      final currentService = ref.read(servicePriorityProvider).currentService;
      if (currentService != null && currentService != service) {
        final serviceList = _config.priorityOrderOfServices;
        final currentPriority = serviceList.indexOf(currentService);
        final recoveredPriority = serviceList.indexOf(service);

        // If recovered service is higher priority AND was our original primary
        if (recoveredPriority >= 0 &&
            (currentPriority < 0 || recoveredPriority < currentPriority) &&
            _originalPrimaryService == service) {
          _log(
              '[Orchestrator] Original primary $service recovered - switching back');

          // Reset cycling state so the recovered service gets a fresh evaluation
          // This ensures that if it has no playback, it will cycle to the next service
          _resetCyclingState();

          // Remember the original primary again since we're switching back to it
          _originalPrimaryService = service;

          ref.read(servicePriorityProvider.notifier).switchToService(service);
        }
      }
    }
  }

  /// Get the current health state for a service
  ServiceHealthState? getServiceHealth(ServiceType service) {
    final provider = service == ServiceType.localSonos ? 'sonos' : 'spotify';
    return _serviceHealth[provider];
  }

  /// Check if a service is healthy and usable
  bool isServiceHealthy(ServiceType service) {
    final health = getServiceHealth(service);
    return health == null || health.status.isHealthy;
  }

  /// Handle when a service reports paused/stopped - start timer to cycle
  /// Note: For Sonos, use _handleSonosPausedWithStatus instead for state-based handling
  void _handleServicePaused(ServiceType service) {
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
      _log(
          '[Orchestrator] $service not playing - cycling disabled (waitSec=0)');
      return;
    }

    _log(
        '[Orchestrator] $service not playing - waiting ${waitSec}s before cycling');

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
  void _handleSonosPausedWithStatus(String? status,
      {bool hasTrackInfo = true}) {
    // Skip if we already have a pause timer running for Sonos
    if (_pausedService == ServiceType.localSonos &&
        _servicePausedTimer != null) {
      return;
    }

    // Skip if Sonos has already been checked this cycle and found not playing
    // This prevents infinite loops when all services are paused/stopped
    if (_checkedNotPlaying.contains(ServiceType.localSonos)) {
      return;
    }

    // Cancel any existing timer
    _cancelPauseTimer();

    // Determine wait time based on Sonos status and track info
    final int waitSec;
    final normalizedStatus = (status ?? 'idle').toLowerCase();

    // "paused" but no track info means user has switched away from Sonos
    // This should ALWAYS use the short idle wait time - the user has actively
    // switched to another device/app, so we should check other services quickly
    if (normalizedStatus == 'paused' && !hasTrackInfo) {
      _log(
          '[Orchestrator] Sonos paused with no track - user switched away, checking other services');
      waitSec = _config.localSonosIdleWaitSec;
    } else {
      switch (normalizedStatus) {
        case 'paused':
          // True pause with track info - user may resume
          waitSec = _config.localSonosPausedWaitSec;
          break;
        case 'stopped':
          waitSec = _config.localSonosStoppedWaitSec;
          break;
        case 'transitioning':
        case 'buffering':
          // Don't cycle during transitioning/buffering - temporary state
          _log('[Orchestrator] Sonos transitioning/buffering - not cycling');
          return;
        case 'playing':
          // Should not reach here, but just in case
          return;
        default:
          // idle, no_media, or unknown - use idle wait time
          waitSec = _config.localSonosIdleWaitSec;
      }
    }

    // 0 means disabled - don't cycle for this status
    if (waitSec <= 0) {
      _log(
          '[Orchestrator] Sonos $normalizedStatus - cycling disabled (waitSec=0)');
      return;
    }

    _log(
        '[Orchestrator] Sonos $normalizedStatus (hasTrack=$hasTrackInfo) - waiting ${waitSec}s before cycling');

    _pausedService = ServiceType.localSonos;
    _servicePausedTimer = Timer(Duration(seconds: waitSec), () {
      _onServicePauseTimerExpired(ServiceType.localSonos);
    });
  }

  /// Called when pause timer expires - try next service in priority
  void _onServicePauseTimerExpired(ServiceType service) {
    _log('[Orchestrator] Pause timer expired for $service');

    _servicePausedTimer = null;
    _pausedService = null;

    // Mark this service as checked
    _checkedNotPlaying.add(service);

    // If this is a Spotify service, also mark the other Spotify service as checked
    // (they use the same account, so if one isn't playing, neither is the other)
    if (service == ServiceType.directSpotify) {
      _checkedNotPlaying.add(ServiceType.cloudSpotify);
      _log(
          '[Orchestrator] Also marking cloudSpotify as checked (same account)');
    } else if (service == ServiceType.cloudSpotify) {
      _checkedNotPlaying.add(ServiceType.directSpotify);
      _log(
          '[Orchestrator] Also marking directSpotify as checked (same account)');
    }

    // Remember the original primary service if not set
    if (_originalPrimaryService == null) {
      _originalPrimaryService = _getHighestPriorityEnabledService();
      _log(
          '[Orchestrator] Remembering primary service: $_originalPrimaryService');
    }

    // Find next service to try
    final nextService = _getNextServiceToTry();

    if (nextService != null) {
      _log('[Orchestrator] Cycling to next service: $nextService');
      _waitingForPrimaryResume = true;

      // Use switchToService in priority manager
      ref.read(servicePriorityProvider.notifier).switchToService(nextService);

      // Re-send WebSocket config to keep listening for primary service resume
      // Keep sonos enabled if primary is localSonos
      final keepSonos = _originalPrimaryService == ServiceType.localSonos;
      ref.read(eventsWsProvider.notifier).sendConfigForService(
            nextService,
            keepSonosEnabled: keepSonos,
          );
    } else {
      // All services checked, none playing
      _log('[Orchestrator] All services checked - none playing');
      _startCycleResetTimer();

      // Stay on or switch to first priority service
      final firstService = _getHighestPriorityEnabledService();
      if (firstService != null) {
        final current = ref.read(servicePriorityProvider).currentService;
        if (current != firstService) {
          ref
              .read(servicePriorityProvider.notifier)
              .switchToService(firstService);
        }
      }

      // Reset waiting state since we've exhausted options
      _waitingForPrimaryResume = false;
      _originalPrimaryService = null;
    }
  }

  /// Immediately cycle to next service (called when service becomes unavailable)
  void _cycleToNextService(ServiceType fromService) {
    // Mark the current service as checked
    _checkedNotPlaying.add(fromService);

    // Cancel any existing pause timer
    _cancelPauseTimer();

    // Remember the original primary service if not set
    if (_originalPrimaryService == null) {
      _originalPrimaryService = _getHighestPriorityEnabledService();
    }

    // Find next service to try
    final nextService = _getNextServiceToTry();

    if (nextService != null) {
      _log(
          '[Orchestrator] Cycling to next service: $nextService (from $fromService)');
      _waitingForPrimaryResume = true;

      ref.read(servicePriorityProvider.notifier).switchToService(nextService);

      // Keep listening for the original service to recover
      final keepSonos = _originalPrimaryService == ServiceType.localSonos;
      ref.read(eventsWsProvider.notifier).sendConfigForService(
            nextService,
            keepSonosEnabled: keepSonos,
          );
    } else {
      // All services checked - none available
      _log('[Orchestrator] All services checked - none available');
      _startCycleResetTimer();
    }
  }

  /// Get the next service to try (respecting priority, skipping checked services)
  ServiceType? _getNextServiceToTry() {
    final priority = ref.read(servicePriorityProvider);

    for (final service in _config.priorityOrderOfServices) {
      // Skip if not enabled
      if (!priority.enabledServices.contains(service)) continue;

      // Skip if already checked this cycle
      if (_checkedNotPlaying.contains(service)) continue;

      // Skip if not available (in cooldown, etc.)
      if (!priority.isServiceAvailable(service)) continue;

      return service;
    }

    return null;
  }

  /// Get highest priority enabled service
  ServiceType? _getHighestPriorityEnabledService() {
    final priority = ref.read(servicePriorityProvider);

    for (final service in _config.priorityOrderOfServices) {
      if (priority.enabledServices.contains(service)) {
        return service;
      }
    }

    return null;
  }

  /// Called when the primary service we were waiting for resumes
  void _handlePrimaryServiceResumed() {
    final primaryService = _originalPrimaryService;
    _log(
        '[Orchestrator] Primary service resumed - switching back to $primaryService');

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
    _log('[Orchestrator] Starting cycle reset timer (${resetSec}s)');

    _cycleResetTimer = Timer(Duration(seconds: resetSec), () {
      _log(
          '[Orchestrator] Cycle reset timer expired - clearing checked services');
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
      _log('[Orchestrator] Timeout waiting for data from $currentService');
      ref.read(servicePriorityProvider.notifier).reportTimeout(currentService);
    });
  }

  void _startDataTimeoutWatcher() {
    // Check every 5 seconds if we're receiving data
    _dataWatchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final priority = ref.read(servicePriorityProvider);
      final currentService = priority.currentService;
      if (currentService == null) return;

      // Get fallback config for this service type
      final fallbackConfig = _config.getFallbackConfig(currentService);

      // Only check timeout if timeoutSec > 0 (disabled for event-driven services like Sonos)
      if (fallbackConfig.timeoutSec <= 0) return;

      // Check if we haven't received data for too long
      if (_lastDataTime != null) {
        final elapsed = DateTime.now().difference(_lastDataTime!).inSeconds;
        if (elapsed > fallbackConfig.timeoutSec) {
          _log(
              '[Orchestrator] No data received for ${elapsed}s from $currentService');
          ref
              .read(servicePriorityProvider.notifier)
              .reportTimeout(currentService);
          _lastDataTime = DateTime.now(); // Reset to prevent repeated triggers
        }
      }
    });
  }

  /// Called when user settings change (e.g., from settings page)
  void updateServicesEnabled({
    required bool spotifyEnabled,
    required bool sonosEnabled,
  }) {
    _log(
        '[Orchestrator] Services updated: spotify=$spotifyEnabled, sonos=$sonosEnabled');

    // If Spotify is being disabled, immediately stop direct polling
    // This ensures polling stops even if service switching hasn't occurred yet
    if (!spotifyEnabled) {
      _log('[Orchestrator] Spotify disabled - stopping direct polling');
      ref.read(spotifyDirectProvider.notifier).stopPolling();
    }

    // Collect unhealthy services so we don't auto-switch to them
    final unhealthyServices = <ServiceType>{};
    for (final entry in _serviceHealth.entries) {
      if (!entry.value.status.isHealthy) {
        final serviceType = entry.key == 'sonos'
            ? ServiceType.localSonos
            : (entry.key == 'spotify' ? ServiceType.cloudSpotify : null);
        if (serviceType != null) {
          unhealthyServices.add(serviceType);
        }
      }
    }
    _log('[Orchestrator] Unhealthy services: $unhealthyServices');

    ref.read(servicePriorityProvider.notifier).updateEnabledServices(
          spotifyEnabled: spotifyEnabled,
          sonosEnabled: sonosEnabled,
          unhealthyServices: unhealthyServices,
        );

    // Re-evaluate active service - force switch if current is no longer enabled
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    if (currentService == null) {
      // No current service, activate first available
      ref.read(servicePriorityProvider.notifier).activateFirstAvailable();
    } else if (!priority.enabledServices.contains(currentService)) {
      // Current service is disabled, must switch
      _log(
          '[Orchestrator] Current service $currentService is now disabled, forcing switch');
      ref.read(servicePriorityProvider.notifier).activateFirstAvailable();
    }
  }

  /// Manually switch to a specific service (for debugging/testing)
  void switchToService(ServiceType service) {
    _log('[Orchestrator] Manual switch to $service');
    ref.read(servicePriorityProvider.notifier).activateService(service);
  }

  /// Force reconnect/restart the current service
  /// Called when app resumes from background after being idle
  void reconnect() {
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    _log('[Orchestrator] Reconnecting current service: $currentService');

    // Cancel any existing pause timer since it may not have fired while app was suspended
    // This allows fresh cycling evaluation when new data arrives
    _cancelPauseTimer();

    if (currentService != null) {
      _activateService(currentService);
    }
  }

  /// Reset everything and start fresh
  void reset() {
    _log('[Orchestrator] Reset requested');

    _timeoutTimer?.cancel();
    _dataWatchTimer?.cancel();
    _cancelPauseTimer();
    _cycleResetTimer?.cancel();
    _lastDataTime = null;
    _initialized = false;

    // Reset cycling state
    _resetCyclingState();
    _lastIsPlaying.clear();

    // Clear service health tracking
    _serviceHealth.clear();

    ref.read(servicePriorityProvider.notifier).reset();
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    state = const UnifiedPlaybackState(isLoading: true);

    // Re-initialize
    Future.microtask(() => _initialize());
  }

  /// Stop all services and timers (called on logout)
  void _stopAllServices() {
    _log('[Orchestrator] Stopping all services');

    // Cancel all timers
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _dataWatchTimer?.cancel();
    _dataWatchTimer = null;
    _cancelPauseTimer();
    _cycleResetTimer?.cancel();
    _cycleResetTimer = null;

    // Reset state
    _lastDataTime = null;
    _initialized = false;
    _resetCyclingState();
    _lastIsPlaying.clear();

    // Clear service health tracking
    _serviceHealth.clear();

    // Stop services
    ref.read(servicePriorityProvider.notifier).reset();
    ref.read(spotifyDirectProvider.notifier).stopPolling();

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

/// Convenience provider to check if we're using any cloud service
final isCloudServiceActiveProvider = Provider<bool>((ref) {
  final service = ref.watch(activeServiceProvider);
  return service?.isCloudService ?? false;
});
