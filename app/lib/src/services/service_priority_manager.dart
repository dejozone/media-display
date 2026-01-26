import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';

/// Status of a service in the priority system
enum ServiceStatus {
  /// Service is currently providing data
  active,

  /// Service is available but not currently active
  standby,

  /// Service is experiencing errors (counting toward threshold)
  failing,

  /// Service is in cooldown after reaching error threshold
  cooldown,

  /// Service is disabled by user settings
  disabled,
}

/// State for tracking service priority and status
@immutable
class ServicePriorityState {
  const ServicePriorityState({
    required this.configuredOrder,
    required this.enabledServices,
    required this.currentService,
    required this.serviceStatuses,
    required this.errorCounts,
    required this.cooldownEnds,
    required this.lastRetryAttempts,
    required this.retryWindowStarts,
    this.previousService,
    this.isTransitioning = false,
    this.transitionStartTime,
    this.lastDataTime,
  });

  /// Priority order from configuration
  final List<ServiceType> configuredOrder;

  /// Services that are enabled based on user settings
  final Set<ServiceType> enabledServices;

  /// Currently active service (or null if none)
  final ServiceType? currentService;

  /// Previous service (for transition tracking)
  final ServiceType? previousService;

  /// Status of each service
  final Map<ServiceType, ServiceStatus> serviceStatuses;

  /// Error count for each service
  final Map<ServiceType, int> errorCounts;

  /// When cooldown ends for each service
  final Map<ServiceType, DateTime?> cooldownEnds;

  /// Last retry attempt time for each service
  final Map<ServiceType, DateTime?> lastRetryAttempts;

  /// When retry window started for each service
  final Map<ServiceType, DateTime?> retryWindowStarts;

  /// Whether we're currently transitioning between services
  final bool isTransitioning;

  /// When the transition started
  final DateTime? transitionStartTime;

  /// Last time we received data from any service
  final DateTime? lastDataTime;

  /// Get the effective priority order (filtered by enabled services)
  List<ServiceType> get effectiveOrder {
    return configuredOrder.where((s) => enabledServices.contains(s)).toList();
  }

  /// Check if a service is available (not in cooldown or disabled)
  bool isServiceAvailable(ServiceType service) {
    final status = serviceStatuses[service];
    return status != ServiceStatus.cooldown && status != ServiceStatus.disabled;
  }

  /// Get the next available service based on priority
  ServiceType? getNextAvailableService() {
    for (final service in effectiveOrder) {
      if (isServiceAvailable(service)) {
        return service;
      }
    }
    return null;
  }

  /// Check if we should retry a service that's in fallback
  bool shouldRetryService(ServiceType service, EnvConfig config) {
    final status = serviceStatuses[service];
    if (status != ServiceStatus.cooldown && status != ServiceStatus.standby) {
      return false;
    }

    final cooldownEnd = cooldownEnds[service];
    if (cooldownEnd != null && DateTime.now().isBefore(cooldownEnd)) {
      return false; // Still in cooldown
    }

    final retryWindowStart = retryWindowStarts[service];
    final fallbackConfig = _getFallbackConfig(service, config);

    // Check if we've exceeded the max retry window
    if (retryWindowStart != null) {
      final windowElapsed =
          DateTime.now().difference(retryWindowStart).inSeconds;
      if (windowElapsed > fallbackConfig.retryMaxWindowSec) {
        return false; // Exceeded retry window
      }
    }

    // Check if enough time has passed since last retry
    final lastRetry = lastRetryAttempts[service];
    if (lastRetry != null) {
      final elapsed = DateTime.now().difference(lastRetry).inSeconds;
      return elapsed >= fallbackConfig.retryIntervalSec;
    }

    return true; // No previous retry, can retry now
  }

  ServiceFallbackConfig _getFallbackConfig(
      ServiceType service, EnvConfig config) {
    // Use the centralized helper method from EnvConfig
    return config.getFallbackConfig(service);
  }

  ServicePriorityState copyWith({
    List<ServiceType>? configuredOrder,
    Set<ServiceType>? enabledServices,
    ServiceType? currentService,
    ServiceType? previousService,
    Map<ServiceType, ServiceStatus>? serviceStatuses,
    Map<ServiceType, int>? errorCounts,
    Map<ServiceType, DateTime?>? cooldownEnds,
    Map<ServiceType, DateTime?>? lastRetryAttempts,
    Map<ServiceType, DateTime?>? retryWindowStarts,
    bool? isTransitioning,
    DateTime? transitionStartTime,
    DateTime? lastDataTime,
    bool clearCurrentService = false,
    bool clearPreviousService = false,
    bool clearTransitionStartTime = false,
    bool clearLastDataTime = false,
  }) {
    return ServicePriorityState(
      configuredOrder: configuredOrder ?? this.configuredOrder,
      enabledServices: enabledServices ?? this.enabledServices,
      currentService:
          clearCurrentService ? null : (currentService ?? this.currentService),
      previousService: clearPreviousService
          ? null
          : (previousService ?? this.previousService),
      serviceStatuses: serviceStatuses ?? this.serviceStatuses,
      errorCounts: errorCounts ?? this.errorCounts,
      cooldownEnds: cooldownEnds ?? this.cooldownEnds,
      lastRetryAttempts: lastRetryAttempts ?? this.lastRetryAttempts,
      retryWindowStarts: retryWindowStarts ?? this.retryWindowStarts,
      isTransitioning: isTransitioning ?? this.isTransitioning,
      transitionStartTime: clearTransitionStartTime
          ? null
          : (transitionStartTime ?? this.transitionStartTime),
      lastDataTime:
          clearLastDataTime ? null : (lastDataTime ?? this.lastDataTime),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ServicePriorityState &&
        listEquals(other.configuredOrder, configuredOrder) &&
        setEquals(other.enabledServices, enabledServices) &&
        other.currentService == currentService &&
        other.previousService == previousService &&
        mapEquals(other.serviceStatuses, serviceStatuses) &&
        mapEquals(other.errorCounts, errorCounts) &&
        other.isTransitioning == isTransitioning;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(configuredOrder),
        Object.hashAllUnordered(enabledServices),
        currentService,
        previousService,
        Object.hashAllUnordered(serviceStatuses.entries),
        Object.hashAllUnordered(errorCounts.entries),
        isTransitioning,
      );

  @override
  String toString() {
    return 'ServicePriorityState('
        'current: $currentService, '
        'effectiveOrder: $effectiveOrder, '
        'statuses: $serviceStatuses, '
        'errors: $errorCounts, '
        'transitioning: $isTransitioning)';
  }
}

/// Notifier for managing service priority state
class ServicePriorityNotifier extends Notifier<ServicePriorityState> {
  Timer? _retryTimer;

  EnvConfig get _config => ref.read(envConfigProvider);

  @override
  ServicePriorityState build() {
    final config = _config;
    final initialStatuses = <ServiceType, ServiceStatus>{};
    final initialErrors = <ServiceType, int>{};
    final initialCooldowns = <ServiceType, DateTime?>{};
    final initialRetries = <ServiceType, DateTime?>{};
    final initialRetryWindows = <ServiceType, DateTime?>{};

    for (final service in ServiceType.values) {
      initialStatuses[service] = ServiceStatus.standby;
      initialErrors[service] = 0;
      initialCooldowns[service] = null;
      initialRetries[service] = null;
      initialRetryWindows[service] = null;
    }

    ref.onDispose(() {
      _retryTimer?.cancel();
    });

    return ServicePriorityState(
      configuredOrder: config.priorityOrderOfServices,
      enabledServices: {},
      currentService: null,
      serviceStatuses: initialStatuses,
      errorCounts: initialErrors,
      cooldownEnds: initialCooldowns,
      lastRetryAttempts: initialRetries,
      retryWindowStarts: initialRetryWindows,
    );
  }

  /// Update enabled services based on user settings
  void updateEnabledServices({
    required bool spotifyEnabled,
    required bool sonosEnabled,
  }) {
    final enabled = <ServiceType>{};

    // Each service has its own requirements from user settings
    for (final service in ServiceType.values) {
      // Check if service requirements are met
      final requiresSpotify = service.requiresSpotify;
      final requiresSonos = service.requiresSonos;

      // Service is enabled if its requirements are satisfied
      if (requiresSpotify && spotifyEnabled) {
        enabled.add(service);
      } else if (requiresSonos && sonosEnabled) {
        enabled.add(service);
      }
    }

    // Update statuses for disabled services
    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    for (final service in ServiceType.values) {
      if (!enabled.contains(service)) {
        newStatuses[service] = ServiceStatus.disabled;
      } else if (newStatuses[service] == ServiceStatus.disabled) {
        newStatuses[service] = ServiceStatus.standby;
      }
    }

    state = state.copyWith(
      enabledServices: enabled,
      serviceStatuses: newStatuses,
    );

    debugPrint(
        '[ServicePriority] Updated enabled services: $enabled (spotify=$spotifyEnabled, sonos=$sonosEnabled)');

    // If current service is now disabled, switch to next available
    final currentService = state.currentService;
    debugPrint(
        '[ServicePriority] Checking if current service needs switch: currentService=$currentService, isInEnabled=${currentService != null ? enabled.contains(currentService) : 'n/a'}');

    if (currentService != null && !enabled.contains(currentService)) {
      debugPrint(
          '[ServicePriority] Current service $currentService is disabled, finding next available');
      final next = state.getNextAvailableService();
      debugPrint('[ServicePriority] Next available service: $next');
      if (next != null) {
        activateService(next);
      } else {
        debugPrint(
            '[ServicePriority] No next service available, clearing current');
        state = state.copyWith(clearCurrentService: true);
      }
    } else if (currentService != null) {
      // Current service is still enabled, but check if a higher-priority service
      // has become available (e.g., Sonos was re-enabled and cloudSonos is higher priority)
      final nextAvailable = state.getNextAvailableService();
      if (nextAvailable != null && nextAvailable != currentService) {
        final currentIndex = state.effectiveOrder.indexOf(currentService);
        final nextIndex = state.effectiveOrder.indexOf(nextAvailable);
        if (nextIndex < currentIndex) {
          debugPrint(
              '[ServicePriority] Higher-priority service $nextAvailable is now available (was on $currentService)');
          activateService(nextAvailable);
        }
      }
    }
  }

  /// Activate a specific service
  void activateService(ServiceType service) {
    if (!state.enabledServices.contains(service)) {
      debugPrint(
          '[ServicePriority] Cannot activate disabled service: $service');
      return;
    }

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);

    // Deactivate current service
    if (state.currentService != null && state.currentService != service) {
      newStatuses[state.currentService!] = ServiceStatus.standby;
    }

    // Activate new service
    newStatuses[service] = ServiceStatus.active;

    // Reset error count for the activated service
    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    newErrors[service] = 0;

    // Start transition
    state = state.copyWith(
      currentService: service,
      previousService: state.currentService,
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      isTransitioning: true,
      transitionStartTime: DateTime.now(),
    );

    debugPrint('[ServicePriority] Activated service: $service');

    // End transition after grace period
    Future.delayed(Duration(seconds: _config.serviceTransitionGraceSec), () {
      if (state.currentService == service) {
        state = state.copyWith(
          isTransitioning: false,
          clearTransitionStartTime: true,
          clearPreviousService: true,
        );
      }
    });
  }

  /// Report a successful data fetch from a service
  void reportSuccess(ServiceType service) {
    if (state.currentService != service) return;

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    newErrors[service] = 0;

    // Clear retry window if we were recovering
    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    newRetryWindows[service] = null;

    state = state.copyWith(
      errorCounts: newErrors,
      retryWindowStarts: newRetryWindows,
      lastDataTime: DateTime.now(),
    );

    // If primary service is succeeding, cancel retry timer
    if (service == _getFirstEnabledService()) {
      _cancelRetryTimer();
    }
  }

  /// Report an error from a service
  void reportError(ServiceType service, {bool is401 = false}) {
    // 401 errors should trigger token refresh, not fallback
    if (is401) {
      debugPrint(
          '[ServicePriority] 401 error on $service - triggering token refresh, not fallback');
      return;
    }

    final fallbackConfig = _config.getFallbackConfig(service);

    if (!fallbackConfig.onError) {
      debugPrint('[ServicePriority] Fallback on error disabled for $service');
      return;
    }

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final currentCount = newErrors[service] ?? 0;
    newErrors[service] = currentCount + 1;

    debugPrint(
        '[ServicePriority] Error on $service (${newErrors[service]}/${fallbackConfig.errorThreshold})');

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);

    if (newErrors[service]! >= fallbackConfig.errorThreshold) {
      // Threshold reached - enter cooldown and trigger fallback
      debugPrint(
          '[ServicePriority] Error threshold reached for $service - entering cooldown');

      newStatuses[service] = ServiceStatus.cooldown;

      final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
      newCooldowns[service] = DateTime.now().add(
        Duration(seconds: fallbackConfig.retryCooldownSec),
      );

      // Start retry window if not already started
      final newRetryWindows =
          Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
      if (newRetryWindows[service] == null) {
        newRetryWindows[service] = DateTime.now();
      }

      state = state.copyWith(
        errorCounts: newErrors,
        serviceStatuses: newStatuses,
        cooldownEnds: newCooldowns,
        retryWindowStarts: newRetryWindows,
      );

      // Trigger fallback to next service
      _triggerFallback(service);
    } else {
      // Update error count but don't fallback yet
      newStatuses[service] = ServiceStatus.failing;
      state = state.copyWith(
        errorCounts: newErrors,
        serviceStatuses: newStatuses,
      );
    }
  }

  /// Report a timeout from a service
  void reportTimeout(ServiceType service) {
    debugPrint('[ServicePriority] Timeout on $service');
    reportError(service);
  }

  void _triggerFallback(ServiceType failedService) {
    // Find next available service in priority order
    final next = state.getNextAvailableService();

    if (next != null && next != failedService) {
      debugPrint('[ServicePriority] Falling back from $failedService to $next');
      activateService(next);
      _startRetryTimer(failedService);
    } else {
      debugPrint('[ServicePriority] No fallback available from $failedService');
      // All services unavailable - stay on current and retry later
      _startRetryTimer(failedService);
    }
  }

  void _startRetryTimer(ServiceType serviceToRetry) {
    _retryTimer?.cancel();

    final fallbackConfig = _config.getFallbackConfig(serviceToRetry);

    _retryTimer = Timer.periodic(
      Duration(seconds: fallbackConfig.retryIntervalSec),
      (_) => _attemptRetryPrimary(),
    );
  }

  void _attemptRetryPrimary() {
    // If we're already on the primary (first) enabled service, cancel the timer
    final primaryService = _getFirstEnabledService();
    if (state.currentService == primaryService) {
      _cancelRetryTimer();
      return;
    }

    // Only attempt retry if the current service is failing or in cooldown
    // Don't switch away from a service that's still working (active status with low error count)
    final currentStatus = state.serviceStatuses[state.currentService];
    final currentErrors = state.errorCounts[state.currentService] ?? 0;
    final currentFallbackConfig = state.currentService != null
        ? _config.getFallbackConfig(state.currentService!)
        : _config.spotifyDirectFallback;

    // If current service is active and hasn't reached error threshold, don't retry others
    if (currentStatus == ServiceStatus.active &&
        currentErrors < currentFallbackConfig.errorThreshold) {
      debugPrint(
          '[ServicePriority] Skipping retry - current service ${state.currentService} is active with $currentErrors/${currentFallbackConfig.errorThreshold} errors');
      return;
    }

    // Find the highest priority service that's in cooldown/standby and ready for retry
    for (final service in state.effectiveOrder) {
      if (service == state.currentService) continue;

      if (state.shouldRetryService(service, _config)) {
        debugPrint('[ServicePriority] Attempting retry of $service');

        // Update last retry attempt
        final newRetries =
            Map<ServiceType, DateTime?>.from(state.lastRetryAttempts);
        newRetries[service] = DateTime.now();

        // Move from cooldown to standby for retry attempt
        final newStatuses =
            Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
        newStatuses[service] = ServiceStatus.standby;

        // Reset error count for retry
        final newErrors = Map<ServiceType, int>.from(state.errorCounts);
        newErrors[service] = 0;

        state = state.copyWith(
          lastRetryAttempts: newRetries,
          serviceStatuses: newStatuses,
          errorCounts: newErrors,
        );

        // Switch to this service for retry
        activateService(service);
        break;
      }
    }
  }

  /// Manually request activation of the first available service
  void activateFirstAvailable() {
    final service = state.getNextAvailableService();
    if (service != null) {
      activateService(service);
    }
  }

  /// Called when WebSocket successfully reconnects
  /// Resets cooldowns for cloud services so they can be retried
  /// and re-evaluates if we should switch back to a higher-priority cloud service
  void onWebSocketReconnected() {
    debugPrint(
        '[ServicePriority] WebSocket reconnected - re-evaluating cloud services');

    // Reset cooldowns and error counts for cloud services
    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);

    for (final service in ServiceType.values) {
      if (service.isCloudService && state.enabledServices.contains(service)) {
        // Reset cloud services that were in cooldown or failing
        final status = newStatuses[service];
        if (status == ServiceStatus.cooldown ||
            status == ServiceStatus.failing) {
          debugPrint(
              '[ServicePriority] Resetting $service from $status to standby');
          newStatuses[service] = ServiceStatus.standby;
          newErrors[service] = 0;
          newCooldowns[service] = null;
          newRetryWindows[service] = null;
        }
      }
    }

    state = state.copyWith(
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      cooldownEnds: newCooldowns,
      retryWindowStarts: newRetryWindows,
    );

    // Check if a higher-priority cloud service should be activated
    final currentService = state.currentService;
    final nextAvailable = state.getNextAvailableService();

    if (nextAvailable != null && nextAvailable != currentService) {
      // Check if the next available is higher priority than current
      final currentIndex = currentService != null
          ? state.effectiveOrder.indexOf(currentService)
          : state.effectiveOrder.length;
      final nextIndex = state.effectiveOrder.indexOf(nextAvailable);

      if (nextIndex < currentIndex) {
        debugPrint(
            '[ServicePriority] Switching to higher-priority service: $nextAvailable (was $currentService)');
        activateService(nextAvailable);

        // If switching to primary service, cancel retry timer
        if (nextAvailable == _getFirstEnabledService()) {
          _cancelRetryTimer();
        }
      }
    }
  }

  /// Reset all services to initial state
  void reset() {
    _retryTimer?.cancel();
    state = build();
  }

  /// Stop all retry timers
  void stopRetryTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Get the first (highest priority) enabled service
  ServiceType? _getFirstEnabledService() {
    final order = state.effectiveOrder;
    return order.isNotEmpty ? order.first : null;
  }

  /// Cancel the retry timer
  void _cancelRetryTimer() {
    if (_retryTimer != null) {
      debugPrint(
          '[ServicePriority] Cancelling retry timer - on primary service');
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }
}

/// Provider for service priority management
final servicePriorityProvider =
    NotifierProvider<ServicePriorityNotifier, ServicePriorityState>(() {
  return ServicePriorityNotifier();
});
