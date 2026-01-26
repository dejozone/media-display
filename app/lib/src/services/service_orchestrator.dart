import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/events_ws_service.dart';
import 'package:media_display/src/services/service_priority_manager.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/spotify_direct_service.dart';
import 'package:media_display/src/services/user_service.dart';

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

      debugPrint(
          '[Orchestrator] Settings loaded: spotify=$spotifyEnabled, sonos=$sonosEnabled');

      // Update service priority with enabled services
      ref.read(servicePriorityProvider.notifier).updateEnabledServices(
            spotifyEnabled: spotifyEnabled,
            sonosEnabled: sonosEnabled,
          );
    } catch (e) {
      debugPrint('[Orchestrator] Failed to load settings: $e');
    }
  }

  void _startServiceWatchers() {
    // Watch auth state changes to stop everything on logout
    ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (prev?.isAuthenticated == true && !next.isAuthenticated) {
        debugPrint('[Orchestrator] User logged out - stopping all services');
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
      debugPrint(
          '[Orchestrator] Active service changed: $prevService -> $currentService');

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
      debugPrint('[Orchestrator] No service to activate');
      return;
    }

    debugPrint('[Orchestrator] Activating service: $service');

    if (service.isDirectPolling) {
      _activateDirectSpotify();
    } else {
      // cloud_spotify or local_sonos
      _activateCloudService(service);
    }
  }

  void _activateDirectSpotify() {
    debugPrint('[Orchestrator] Activating direct Spotify polling');

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
    debugPrint('[Orchestrator] Activating cloud service: $service');

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
        debugPrint(
            '[Orchestrator] Primary service directSpotify resumed playing!');
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
        debugPrint(
            '[Orchestrator] Direct Spotify 401 - token refresh triggered');
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
      debugPrint(
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
          debugPrint('[Orchestrator] Spotify not playing (was: $wasPlaying)');
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
        debugPrint(
            '[Orchestrator] Primary service $dataSource resumed playing!');
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
        debugPrint(
            '[Orchestrator] Cloud service disconnected: ${wsState.error}');
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
      final wasPlaying = _lastIsPlaying[effectiveService] ?? false;
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
          debugPrint(
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
        debugPrint(
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

          // Only log on state transition (from playing to not playing)
          if (wasPlaying) {
            debugPrint(
                '[Orchestrator] $effectiveService not playing - status: $status, hasTrackInfo: $hasTrackInfo');
          }

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
        debugPrint(
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

  /// Handle when a service reports paused/stopped - start timer to cycle
  /// Note: For Sonos, use _handleSonosPausedWithStatus instead for state-based handling
  void _handleServicePaused(ServiceType service) {
    // Skip if we already have a pause timer running for this service
    if (_pausedService == service && _servicePausedTimer != null) return;

    // Cancel any existing timer for a different service
    _cancelPauseTimer();

    // Get the pause wait duration for this service (for Spotify services)
    final waitSec = _config.spotifyPausedWaitSec;

    // 0 means disabled - don't cycle for this service
    if (waitSec <= 0) {
      debugPrint(
          '[Orchestrator] $service not playing - cycling disabled (waitSec=0)');
      return;
    }

    debugPrint(
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
  /// - paused (no track): treat as idle - user switched away
  /// - stopped: longer wait (e.g., 30s) - queue might have ended
  /// - idle/no_media: quick switch (e.g., 3s) - nothing to play
  void _handleSonosPausedWithStatus(String? status,
      {bool hasTrackInfo = true}) {
    // Skip if we already have a pause timer running for Sonos
    if (_pausedService == ServiceType.localSonos &&
        _servicePausedTimer != null) {
      return;
    }

    // Cancel any existing timer
    _cancelPauseTimer();

    // Determine wait time based on Sonos status and track info
    final int waitSec;
    final normalizedStatus = (status ?? 'idle').toLowerCase();

    // Special case: "paused" but no track info means user likely switched away
    // Treat this as "idle" for quicker fallback
    if (normalizedStatus == 'paused' && !hasTrackInfo) {
      debugPrint(
          '[Orchestrator] Sonos paused with no track info - treating as idle (user likely switched away)');
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
          debugPrint(
              '[Orchestrator] Sonos transitioning/buffering - not cycling');
          return;
        default:
          // idle, no_media, or unknown - use idle wait time
          waitSec = _config.localSonosIdleWaitSec;
      }
    }

    // 0 means disabled - don't cycle for this status
    if (waitSec <= 0) {
      debugPrint(
          '[Orchestrator] Sonos $normalizedStatus - cycling disabled (waitSec=0)');
      return;
    }

    debugPrint(
        '[Orchestrator] Sonos $normalizedStatus (hasTrack=$hasTrackInfo) - waiting ${waitSec}s before cycling');

    _pausedService = ServiceType.localSonos;
    _servicePausedTimer = Timer(Duration(seconds: waitSec), () {
      _onServicePauseTimerExpired(ServiceType.localSonos);
    });
  }

  /// Called when pause timer expires - try next service in priority
  void _onServicePauseTimerExpired(ServiceType service) {
    debugPrint('[Orchestrator] Pause timer expired for $service');

    _servicePausedTimer = null;
    _pausedService = null;

    // Mark this service as checked
    _checkedNotPlaying.add(service);

    // If this is a Spotify service, also mark the other Spotify service as checked
    // (they use the same account, so if one isn't playing, neither is the other)
    if (service == ServiceType.directSpotify) {
      _checkedNotPlaying.add(ServiceType.cloudSpotify);
      debugPrint(
          '[Orchestrator] Also marking cloudSpotify as checked (same account)');
    } else if (service == ServiceType.cloudSpotify) {
      _checkedNotPlaying.add(ServiceType.directSpotify);
      debugPrint(
          '[Orchestrator] Also marking directSpotify as checked (same account)');
    }

    // Remember the original primary service if not set
    if (_originalPrimaryService == null) {
      _originalPrimaryService = _getHighestPriorityEnabledService();
      debugPrint(
          '[Orchestrator] Remembering primary service: $_originalPrimaryService');
    }

    // Find next service to try
    final nextService = _getNextServiceToTry();

    if (nextService != null) {
      debugPrint('[Orchestrator] Cycling to next service: $nextService');
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
      debugPrint('[Orchestrator] All services checked - none playing');
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
    debugPrint(
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
    debugPrint('[Orchestrator] Starting cycle reset timer (${resetSec}s)');

    _cycleResetTimer = Timer(Duration(seconds: resetSec), () {
      debugPrint(
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
      debugPrint(
          '[Orchestrator] Timeout waiting for data from $currentService');
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
          debugPrint(
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
    debugPrint(
        '[Orchestrator] Services updated: spotify=$spotifyEnabled, sonos=$sonosEnabled');

    // If Spotify is being disabled, immediately stop direct polling
    // This ensures polling stops even if service switching hasn't occurred yet
    if (!spotifyEnabled) {
      debugPrint('[Orchestrator] Spotify disabled - stopping direct polling');
      ref.read(spotifyDirectProvider.notifier).stopPolling();
    }

    ref.read(servicePriorityProvider.notifier).updateEnabledServices(
          spotifyEnabled: spotifyEnabled,
          sonosEnabled: sonosEnabled,
        );

    // Re-evaluate active service - force switch if current is no longer enabled
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    if (currentService == null) {
      // No current service, activate first available
      ref.read(servicePriorityProvider.notifier).activateFirstAvailable();
    } else if (!priority.enabledServices.contains(currentService)) {
      // Current service is disabled, must switch
      debugPrint(
          '[Orchestrator] Current service $currentService is now disabled, forcing switch');
      ref.read(servicePriorityProvider.notifier).activateFirstAvailable();
    }
  }

  /// Manually switch to a specific service (for debugging/testing)
  void switchToService(ServiceType service) {
    debugPrint('[Orchestrator] Manual switch to $service');
    ref.read(servicePriorityProvider.notifier).activateService(service);
  }

  /// Force reconnect/restart the current service
  void reconnect() {
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    debugPrint('[Orchestrator] Reconnecting current service: $currentService');

    if (currentService != null) {
      _activateService(currentService);
    }
  }

  /// Reset everything and start fresh
  void reset() {
    debugPrint('[Orchestrator] Reset requested');

    _timeoutTimer?.cancel();
    _dataWatchTimer?.cancel();
    _cancelPauseTimer();
    _cycleResetTimer?.cancel();
    _lastDataTime = null;
    _initialized = false;

    // Reset cycling state
    _resetCyclingState();
    _lastIsPlaying.clear();

    ref.read(servicePriorityProvider.notifier).reset();
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    state = const UnifiedPlaybackState(isLoading: true);

    // Re-initialize
    Future.microtask(() => _initialize());
  }

  /// Stop all services and timers (called on logout)
  void _stopAllServices() {
    debugPrint('[Orchestrator] Stopping all services');

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
