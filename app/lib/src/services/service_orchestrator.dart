import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';
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
  DateTime? _lastDataTime;
  bool _initialized = false;

  EnvConfig get _config => ref.read(envConfigProvider);

  @override
  UnifiedPlaybackState build() {
    ref.onDispose(() {
      _timeoutTimer?.cancel();
      _dataWatchTimer?.cancel();
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

      // Update state with new service
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
      // cloud_spotify or cloud_sonos
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
    ref
        .read(eventsWsProvider.notifier)
        .sendConfigForService(ServiceType.directSpotify);

    // Reset timeout timer
    _resetTimeoutTimer();
  }

  void _activateCloudService(ServiceType service) {
    debugPrint('[Orchestrator] Activating cloud service: $service');

    // Stop direct polling if it was running
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    // Connect/reconnect WebSocket and send config for this service
    ref.read(eventsWsProvider.notifier).connect();
    ref.read(eventsWsProvider.notifier).sendConfigForService(service);

    // Reset timeout timer
    _resetTimeoutTimer();
  }

  void _handleDirectSpotifyChange(SpotifyDirectState spotifyState) {
    final priority = ref.read(servicePriorityProvider);

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
      _processPayload(spotifyState.payload!, ServiceType.directSpotify);
    }
  }

  void _handleCloudServiceChange(NowPlayingState wsState) {
    final priority = ref.read(servicePriorityProvider);
    final currentService = priority.currentService;

    // Only process if a cloud service (cloud_spotify or cloud_sonos) is active
    if (currentService == null || !currentService.isCloudService) return;

    // Check connection status
    if (!wsState.connected) {
      // Check if we're in retry/cooldown or completely disconnected
      if (wsState.error != null && !wsState.wsRetrying) {
        debugPrint(
            '[Orchestrator] Cloud service disconnected: ${wsState.error}');
        ref.read(servicePriorityProvider.notifier).reportError(currentService);
      }
      return;
    }

    // Process payload if available
    if (wsState.payload != null) {
      _processPayload(wsState.payload!, currentService);
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
      debugPrint(
          '[Orchestrator] Received stopped/empty data from $source - music paused/stopped');
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
    _lastDataTime = null;
    _initialized = false;

    ref.read(servicePriorityProvider.notifier).reset();
    ref.read(spotifyDirectProvider.notifier).stopPolling();

    state = const UnifiedPlaybackState(isLoading: true);

    // Re-initialize
    Future.microtask(() => _initialize());
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

/// Convenience provider to check if we're using cloud Sonos
final isCloudSonosActiveProvider = Provider<bool>((ref) {
  return ref.watch(activeServiceProvider) == ServiceType.cloudSonos;
});

/// Convenience provider to check if we're using any cloud service
final isCloudServiceActiveProvider = Provider<bool>((ref) {
  final service = ref.watch(activeServiceProvider);
  return service?.isCloudService ?? false;
});
