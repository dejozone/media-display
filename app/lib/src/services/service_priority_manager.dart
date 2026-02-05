import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/config/env.dart';

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

/// State for tracking recovery of a failed higher-priority service
@immutable
class ServiceRecoveryState {
  const ServiceRecoveryState({
    required this.service,
    required this.windowStartTime,
    this.lastProbeTime,
    this.consecutiveFailures = 0,
    this.inCooldown = false,
    this.cooldownEndTime,
  });

  final ServiceType service;
  final DateTime windowStartTime;
  final DateTime? lastProbeTime;
  final int consecutiveFailures;
  final bool inCooldown;
  final DateTime? cooldownEndTime;

  ServiceRecoveryState copyWith({
    DateTime? windowStartTime,
    DateTime? lastProbeTime,
    int? consecutiveFailures,
    bool? inCooldown,
    DateTime? cooldownEndTime,
    bool clearLastProbeTime = false,
    bool clearCooldownEndTime = false,
  }) {
    return ServiceRecoveryState(
      service: service,
      windowStartTime: windowStartTime ?? this.windowStartTime,
      lastProbeTime:
          clearLastProbeTime ? null : (lastProbeTime ?? this.lastProbeTime),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      inCooldown: inCooldown ?? this.inCooldown,
      cooldownEndTime: clearCooldownEndTime
          ? null
          : (cooldownEndTime ?? this.cooldownEndTime),
    );
  }

  @override
  String toString() {
    return 'RecoveryState($service, failures=$consecutiveFailures, inCooldown=$inCooldown)';
  }
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
    this.unhealthyServices = const {},
    this.awaitingRecovery = const {},
    this.recoveryStates = const {},
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

  /// Services that are known to be unhealthy (from orchestrator health tracking)
  /// Used during fallback to skip services that are recovering/failing
  final Set<ServiceType> unhealthyServices;

  /// Cloud services that have exceeded error emit threshold and are waiting
  /// for server-side recovery. While present here, client should not churn
  /// configs or force fallback; just wait for healthy status.
  final Set<ServiceType> awaitingRecovery;

  /// Recovery states for failed higher-priority services
  /// Key: service type, Value: recovery state
  final Map<ServiceType, ServiceRecoveryState> recoveryStates;

  /// Whether we're currently transitioning between services
  final bool isTransitioning;

  /// When the transition started
  final DateTime? transitionStartTime;

  /// Last time we received data from any service
  final DateTime? lastDataTime;

  /// Get services that need recovery (higher priority than current, in recovery state)
  List<ServiceType> get servicesNeedingRecovery {
    if (currentService == null) return [];
    final currentIndex = configuredOrder.indexOf(currentService!);
    if (currentIndex < 0) return [];

    return recoveryStates.keys.where((service) {
      final serviceIndex = configuredOrder.indexOf(service);
      return serviceIndex >= 0 && serviceIndex < currentIndex;
    }).toList()
      ..sort((a, b) =>
          configuredOrder.indexOf(a).compareTo(configuredOrder.indexOf(b)));
  }

  /// Get the effective priority order (filtered by enabled services)
  List<ServiceType> get effectiveOrder {
    return configuredOrder.where((s) => enabledServices.contains(s)).toList();
  }

  /// Check if a service is available (not in cooldown, disabled, or unhealthy)
  bool isServiceAvailable(ServiceType service) {
    final status = serviceStatuses[service];
    final isUnhealthy = unhealthyServices.contains(service);
    final awaiting =
        awaitingRecovery.contains(service) && service.isCloudService;
    return status != ServiceStatus.cooldown &&
        status != ServiceStatus.disabled &&
        !isUnhealthy &&
        !awaiting;
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

  /// Get the next available service that comes AFTER the given service in the
  /// configured priority order. If none is available after it, returns null.
  ServiceType? getNextAvailableServiceAfter(ServiceType service) {
    final startIdx = effectiveOrder.indexOf(service);
    if (startIdx < 0) return getNextAvailableService();

    for (var i = startIdx + 1; i < effectiveOrder.length; i++) {
      final candidate = effectiveOrder[i];
      if (isServiceAvailable(candidate)) {
        return candidate;
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
    Set<ServiceType>? unhealthyServices,
    Set<ServiceType>? awaitingRecovery,
    Map<ServiceType, ServiceRecoveryState>? recoveryStates,
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
      unhealthyServices: unhealthyServices ?? this.unhealthyServices,
      awaitingRecovery: awaitingRecovery ?? this.awaitingRecovery,
      recoveryStates: recoveryStates ?? this.recoveryStates,
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
        other.isTransitioning == isTransitioning &&
        setEquals(other.unhealthyServices, unhealthyServices) &&
        setEquals(other.awaitingRecovery, awaitingRecovery) &&
        mapEquals(other.recoveryStates, recoveryStates);
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
        Object.hashAllUnordered(unhealthyServices),
        Object.hashAllUnordered(awaitingRecovery),
        Object.hashAllUnordered(recoveryStates.entries),
      );

  @override
  String toString() {
    final recoveryInfo = recoveryStates.isNotEmpty
        ? ', recovery: ${recoveryStates.keys.toList()}'
        : '';
    return 'ServicePriorityState('
        'current: $currentService, '
        'effectiveOrder: $effectiveOrder, '
        'statuses: $serviceStatuses, '
        'errors: $errorCounts, '
        'transitioning: $isTransitioning, '
        'unhealthy: $unhealthyServices$recoveryInfo)';
  }
}

/// Callback type for probing a service's health
typedef ServiceProbeCallback = Future<bool> Function(ServiceType service);

/// Notifier for managing service priority state
class ServicePriorityNotifier extends Notifier<ServicePriorityState> {
  Timer? _retryTimer;
  Timer? _recoveryTimer;
  ServiceProbeCallback? _probeCallback;

  EnvConfig get _config => ref.read(envConfigProvider);

  /// Set the callback for probing service health
  void setProbeCallback(ServiceProbeCallback callback) {
    _probeCallback = callback;
  }

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
      _recoveryTimer?.cancel();
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
      awaitingRecovery: {},
    );
  }

  /// Update enabled services based on user settings
  ///
  /// [unhealthyServices] - Optional set of services known to be unhealthy.
  /// If provided, these services will not be auto-switched to even if they
  /// are higher priority, allowing the current service to continue.
  void updateEnabledServices({
    required bool spotifyEnabled,
    required bool sonosEnabled,
    Set<ServiceType>? unhealthyServices,
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

    _log(
        '[ServicePriority] Updated enabled services: $enabled (spotify=$spotifyEnabled, sonos=$sonosEnabled)');

    // If current service is now disabled, switch to next available
    final currentService = state.currentService;
    _log(
        '[ServicePriority] Checking if current service needs switch: currentService=$currentService, isInEnabled=${currentService != null ? enabled.contains(currentService) : 'n/a'}');

    if (currentService != null && !enabled.contains(currentService)) {
      _log(
          '[ServicePriority] Current service $currentService is disabled, finding next available');
      final next = state.getNextAvailableService();
      _log('[ServicePriority] Next available service: $next');
      if (next != null) {
        activateService(next);
      } else {
        _log('[ServicePriority] No next service available, clearing current');
        state = state.copyWith(clearCurrentService: true);
      }
    } else if (currentService != null) {
      // Current service is still enabled, but check if a higher-priority service
      // has become available (e.g., Sonos was re-enabled and localSonos is higher priority)
      // BUT: Don't switch if that service is known to be unhealthy
      final nextAvailable = state.getNextAvailableService();
      if (nextAvailable != null && nextAvailable != currentService) {
        final currentIndex = state.effectiveOrder.indexOf(currentService);
        final nextIndex = state.effectiveOrder.indexOf(nextAvailable);
        final isHigherPriority = nextIndex < currentIndex;
        final isUnhealthy = unhealthyServices?.contains(nextAvailable) ?? false;

        if (isHigherPriority && !isUnhealthy) {
          _log(
              '[ServicePriority] Higher-priority service $nextAvailable is now available (was on $currentService)');
          activateService(nextAvailable);
        } else if (isHigherPriority && isUnhealthy) {
          _log(
              '[ServicePriority] Higher-priority service $nextAvailable is enabled but unhealthy - staying on $currentService');
        }
      }
    }
  }

  /// Update the set of unhealthy services
  /// Called by the orchestrator when service health changes
  void updateUnhealthyServices(Set<ServiceType> unhealthy) {
    if (!setEquals(state.unhealthyServices, unhealthy)) {
      _log('[ServicePriority] Updated unhealthy services: $unhealthy');
      state = state.copyWith(unhealthyServices: unhealthy);
    }
  }

  /// Mark a cloud service as awaiting server-side recovery to avoid churn
  /// while backend reports failures. Cleared when a healthy status is received.
  void markAwaitingRecovery(ServiceType service) {
    if (!service.isCloudService) return;
    if (state.awaitingRecovery.contains(service)) return;

    final awaiting = Set<ServiceType>.from(state.awaitingRecovery)
      ..add(service);
    state = state.copyWith(awaitingRecovery: awaiting);
    _log('[ServicePriority] Marked $service as awaiting server recovery');
  }

  /// Activate a specific service
  void activateService(ServiceType service) {
    if (!state.enabledServices.contains(service)) {
      _log('[ServicePriority] Cannot activate disabled service: $service');
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

    _log('[ServicePriority] Activated service: $service');

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

  /// Switch to a specific service (for cycling)
  /// Unlike activateService, this doesn't reset error counts or trigger retry logic
  void switchToService(ServiceType service) {
    if (!state.enabledServices.contains(service)) {
      _log('[ServicePriority] Cannot switch to disabled service: $service');
      return;
    }

    if (state.currentService == service) {
      _log('[ServicePriority] Already on service: $service');
      return;
    }

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);

    // Deactivate current service (but don't change its error state)
    if (state.currentService != null) {
      newStatuses[state.currentService!] = ServiceStatus.standby;
    }

    // Activate new service
    newStatuses[service] = ServiceStatus.active;

    state = state.copyWith(
      currentService: service,
      previousService: state.currentService,
      serviceStatuses: newStatuses,
      isTransitioning: true,
      transitionStartTime: DateTime.now(),
    );

    _log('[ServicePriority] Switched to service: $service');

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
      _log(
          '[ServicePriority] 401 error on $service - triggering token refresh, not fallback');
      return;
    }

    // If cloud service is already marked awaiting recovery, only ignore errors
    // when it is NOT the active service. When it's the active service we still
    // need to count errors so we can fall back to the next priority service.
    if (service.isCloudService && state.awaitingRecovery.contains(service)) {
      if (state.currentService != service) {
        _log(
            '[ServicePriority] Error ignored for $service (awaiting recovery, not active)');
        return;
      }

      _log(
          '[ServicePriority] Error on active $service while awaiting recovery - counting toward fallback');
    }

    final fallbackConfig = _config.getFallbackConfig(service);
    final isPrimary = state.effectiveOrder.isNotEmpty &&
        state.effectiveOrder.first == service;
    // When running on a fallback (non-primary) service, cap the threshold to 3
    // so we move down the priority list instead of lingering on repeated failures.
    final effectiveThreshold = (!isPrimary && state.currentService == service)
        ? fallbackConfig.errorThreshold.clamp(1, 3).toInt()
        : fallbackConfig.errorThreshold;

    if (!fallbackConfig.onError) {
      _log('[ServicePriority] Fallback on error disabled for $service');
      return;
    }

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final currentCount = newErrors[service] ?? 0;
    newErrors[service] = currentCount + 1;

    _log('[ServicePriority] Error on $service '
        '(${newErrors[service]}/$effectiveThreshold)');

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);

    // For cloud-hosted services, immediately enter awaiting-recovery state to
    // avoid config churn while the server is still unhealthy. Recovery will be
    // cleared when a healthy status is received.
    if (service.isCloudService && !state.awaitingRecovery.contains(service)) {
      final awaiting = Set<ServiceType>.from(state.awaitingRecovery)
        ..add(service);
      state = state.copyWith(awaitingRecovery: awaiting);
      _log('[ServicePriority] Marked $service as awaiting server recovery');
    }

    if (newErrors[service]! >= effectiveThreshold) {
      // Threshold reached - enter cooldown and trigger fallback
      _log(
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

      // Trigger fallback to the next available service. For cloud services we
      // stay in awaiting-recovery so we won't churn back until the server is
      // healthy again.
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
    _log('[ServicePriority] Timeout on $service');
    reportError(service);
  }

  void _triggerFallback(ServiceType failedService) {
    // Prefer the next available service AFTER the failed one to avoid bouncing
    // back to higher-priority services that were already checked/idle.
    final next = state.getNextAvailableServiceAfter(failedService) ??
        state.getNextAvailableService();

    if (next != null && next != failedService) {
      _log('[ServicePriority] Falling back from $failedService to $next');
      activateService(next);
      _startRetryTimer(failedService);

      // Start recovery monitoring for the failed service if it's higher priority
      startRecovery(failedService);
    } else {
      _log('[ServicePriority] No fallback available from $failedService');
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

    // If current cloud service is awaiting server recovery, do not churn
    if (state.currentService != null &&
        state.currentService!.isCloudService &&
        state.awaitingRecovery.contains(state.currentService)) {
      _log(
          '[ServicePriority] Awaiting recovery for ${state.currentService}; skipping retry');
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
      return;
    }

    // Find the highest priority service that's in cooldown/standby and ready for retry
    for (final service in state.effectiveOrder) {
      if (state.awaitingRecovery.contains(service) && service.isCloudService) {
        // Wait for server-side health recovery for cloud services
        continue;
      }

      // If a service is already in active recovery probing (e.g., directSpotify),
      // let the recovery loop promote it on success instead of force-switching
      // here. This avoids churn away from a healthy fallback while probes run.
      if (state.recoveryStates.containsKey(service)) {
        // _log(
        //     '[ServicePriority] Recovery probe active for $service; letting probe drive switch');
        continue;
      }

      if (service == state.currentService) continue;

      if (state.shouldRetryService(service, _config)) {
        _log('[ServicePriority] Attempting retry of $service');

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
  /// Returns the activated service, or null if none available
  ServiceType? activateFirstAvailable() {
    final service = state.getNextAvailableService();
    if (service != null) {
      activateService(service);
    }
    return service;
  }

  /// Called when WebSocket successfully reconnects
  /// Resets cooldowns for cloud services so they can be retried
  /// and re-evaluates if we should switch back to a higher-priority cloud service
  void onWebSocketReconnected() {
    _log(
        '[ServicePriority] WebSocket reconnected - re-evaluating cloud services');

    // Reset cooldowns and error counts for cloud services
    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    var clearedAwaiting = state.awaitingRecovery;

    for (final service in ServiceType.values) {
      if (service.isCloudService && state.enabledServices.contains(service)) {
        // Reset cloud services that were in cooldown or failing
        final status = newStatuses[service];
        if (status == ServiceStatus.cooldown ||
            status == ServiceStatus.failing) {
          _log('[ServicePriority] Resetting $service from $status to standby');
          newStatuses[service] = ServiceStatus.standby;
          newErrors[service] = 0;
          newCooldowns[service] = null;
          newRetryWindows[service] = null;
        }
      }
    }

    // Clearing awaiting-recovery lets the client retry cloud services after
    // a fresh WebSocket connection instead of being stuck on direct Spotify.
    if (clearedAwaiting.isNotEmpty) {
      _log('[ServicePriority] Clearing awaiting-recovery flags on reconnect');
      clearedAwaiting = <ServiceType>{};
    }

    state = state.copyWith(
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      cooldownEnds: newCooldowns,
      retryWindowStarts: newRetryWindows,
      awaitingRecovery: clearedAwaiting,
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
        _log(
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
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    state = build();
  }

  /// Stop all retry timers
  void stopRetryTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Stop all retry/recovery activity for services below the active one.
  /// Used when a higher-priority service is confirmed playing so we don't churn.
  void quiesceLowerPriorityServices(ServiceType activeService) {
    final activeIndex = state.configuredOrder.indexOf(activeService);
    if (activeIndex < 0) {
      return;
    }

    final newStatuses = Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    final newRetryWindows = Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    final newLastRetries = Map<ServiceType, DateTime?>.from(state.lastRetryAttempts);
    final newAwaiting = Set<ServiceType>.from(state.awaitingRecovery);
    final newRecoveryStates = Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);

    for (final service in ServiceType.values) {
      final idx = state.configuredOrder.indexOf(service);
      if (idx <= activeIndex || idx < 0) continue;

      // Clear retry/error state for lower-priority services.
      newErrors[service] = 0;
      newCooldowns[service] = null;
      newRetryWindows[service] = null;
      newLastRetries[service] = null;
      newAwaiting.remove(service);
      newRecoveryStates.remove(service);

      // Keep them in standby/disabled; do not allow them to re-activate via timers.
      if (newStatuses[service] != ServiceStatus.disabled) {
        newStatuses[service] = ServiceStatus.standby;
      }
    }

    state = state.copyWith(
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      cooldownEnds: newCooldowns,
      retryWindowStarts: newRetryWindows,
      lastRetryAttempts: newLastRetries,
      awaitingRecovery: newAwaiting,
      recoveryStates: newRecoveryStates,
    );

    // Cancel timers if no services are under retry/recovery.
    _cancelRetryTimer();
    if (state.recoveryStates.isEmpty) {
      _stopRecoveryTimer();
    }
  }

  /// Get the first (highest priority) enabled service
  ServiceType? _getFirstEnabledService() {
    final order = state.effectiveOrder;
    return order.isNotEmpty ? order.first : null;
  }

  /// Cancel the retry timer
  void _cancelRetryTimer() {
    if (_retryTimer != null) {
      _log('[ServicePriority] Cancelling retry timer - on primary service');
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  // ============================================================
  // Service Recovery Methods
  // ============================================================

  /// Start recovery monitoring for a failed service that is higher priority than current
  /// Called when a service fails and we fall back to a lower-priority service
  /// NOTE: Only directSpotify is handled client-side. Cloud services (cloudSpotify, localSonos)
  /// have their recovery handled by the WebSocket server.
  void startRecovery(ServiceType failedService) {
    // Only handle directSpotify recovery client-side
    // Cloud services (cloudSpotify, localSonos) recovery is handled by the server
    if (failedService != ServiceType.directSpotify) {
      _log(
          '[ServicePriority] Skipping client-side recovery for $failedService (handled by server)');
      return;
    }

    final currentService = state.currentService;
    if (currentService == null) return;

    // Check if failed service is higher priority than current
    final failedIndex = state.configuredOrder.indexOf(failedService);
    final currentIndex = state.configuredOrder.indexOf(currentService);

    if (failedIndex < 0 || currentIndex < 0) return;
    if (failedIndex >= currentIndex) {
      // Failed service is lower priority - don't start recovery
      return;
    }

    // Check if already in recovery
    if (state.recoveryStates.containsKey(failedService)) {
      _log('[ServicePriority] Recovery already active for $failedService');
      return;
    }

    _log(
        '[ServicePriority] Starting recovery for higher-priority service: $failedService');

    // Create recovery state
    final recoveryState = ServiceRecoveryState(
      service: failedService,
      windowStartTime: DateTime.now(),
    );

    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    newRecoveryStates[failedService] = recoveryState;

    state = state.copyWith(recoveryStates: newRecoveryStates);

    // Start recovery timer if not already running
    _startRecoveryTimer();
  }

  /// Stop recovery monitoring for a service
  void stopRecovery(ServiceType service) {
    if (!state.recoveryStates.containsKey(service)) return;

    _log('[ServicePriority] Stopping recovery for $service');

    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    newRecoveryStates.remove(service);

    state = state.copyWith(recoveryStates: newRecoveryStates);

    // Stop timer if no more services need recovery
    if (newRecoveryStates.isEmpty) {
      _stopRecoveryTimer();
    }
  }

  /// Clear all recovery states (e.g., when user changes settings)
  void clearAllRecovery() {
    if (state.recoveryStates.isEmpty) return;

    _log('[ServicePriority] Clearing all recovery states');
    _stopRecoveryTimer();
    state =
        state.copyWith(recoveryStates: <ServiceType, ServiceRecoveryState>{});
  }

  /// Called when a service is successfully recovered
  /// Switches to the recovered service if it's higher priority than current
  void onServiceRecovered(ServiceType service) {
    if (!state.recoveryStates.containsKey(service) &&
        !state.awaitingRecovery.contains(service)) {
      return;
    }

    final currentService = state.currentService;
    final serviceIndex = state.configuredOrder.indexOf(service);
    final currentIndex = currentService != null
        ? state.configuredOrder.indexOf(currentService)
        : state.configuredOrder.length;

    _log('[ServicePriority] Service $service recovered');

    // Remove from recovery states
    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    newRecoveryStates.remove(service);

    // Clear awaiting recovery flag
    final newAwaiting = Set<ServiceType>.from(state.awaitingRecovery)
      ..remove(service);

    // Reset service status
    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    newStatuses[service] = ServiceStatus.standby;

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    newErrors[service] = 0;

    state = state.copyWith(
      recoveryStates: newRecoveryStates,
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      awaitingRecovery: newAwaiting,
    );

    // Switch to recovered service if it's higher priority
    if (serviceIndex >= 0 && serviceIndex < currentIndex) {
      _log(
          '[ServicePriority] Switching to recovered higher-priority service: $service');
      activateService(service);

      // If we're now on the primary service, cancel retry timer
      if (service == _getFirstEnabledService()) {
        _cancelRetryTimer();
      }
    }

    // Stop timer if no more services need recovery
    if (newRecoveryStates.isEmpty) {
      _stopRecoveryTimer();
    }
  }

  /// Called when a recovery probe fails
  void onRecoveryProbeFailed(ServiceType service) {
    final recoveryState = state.recoveryStates[service];
    if (recoveryState == null) return;

    // Use service-specific fallback config
    final fallbackConfig = _config.getFallbackConfig(service);
    final newFailures = recoveryState.consecutiveFailures + 1;
    final cooldownThreshold = fallbackConfig.errorThreshold;
    final cooldownInterval = fallbackConfig.retryCooldownSec;

    _log(
        '[ServicePriority] Recovery probe failed for $service ($newFailures/$cooldownThreshold)');

    ServiceRecoveryState updatedState;
    if (newFailures >= cooldownThreshold) {
      // Enter cooldown
      _log('[ServicePriority] $service entering recovery cooldown');
      updatedState = recoveryState.copyWith(
        consecutiveFailures: 0, // Reset after entering cooldown
        inCooldown: true,
        cooldownEndTime:
            DateTime.now().add(Duration(seconds: cooldownInterval)),
        lastProbeTime: DateTime.now(),
      );
    } else {
      updatedState = recoveryState.copyWith(
        consecutiveFailures: newFailures,
        lastProbeTime: DateTime.now(),
      );
    }

    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    newRecoveryStates[service] = updatedState;

    state = state.copyWith(recoveryStates: newRecoveryStates);
  }

  void _startRecoveryTimer() {
    if (_recoveryTimer != null) return; // Already running

    // Use directSpotify fallback config for recovery (only directSpotify is recovered client-side)
    final interval = _config.spotifyDirectFallback.retryIntervalSec;
    _log('[ServicePriority] Starting recovery timer (interval: ${interval}s)');

    _recoveryTimer = Timer.periodic(
      Duration(seconds: interval),
      (_) => _onRecoveryTimerTick(),
    );
  }

  void _stopRecoveryTimer() {
    if (_recoveryTimer != null) {
      _log('[ServicePriority] Stopping recovery timer');
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
    }
  }

  void _onRecoveryTimerTick() {
    final servicesToProbe = <ServiceType>[];
    final servicesToRemove = <ServiceType>[];
    final updatedStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    final now = DateTime.now();

    for (final entry in state.recoveryStates.entries) {
      final service = entry.key;
      var recoveryState = entry.value;

      // Get service-specific config
      final fallbackConfig = _config.getFallbackConfig(service);
      final maxWindow = fallbackConfig.retryMaxWindowSec;

      // Check max window (negative = infinite)
      if (maxWindow >= 0) {
        final windowElapsed =
            now.difference(recoveryState.windowStartTime).inSeconds;
        if (windowElapsed >= maxWindow) {
          _log(
              '[ServicePriority] Recovery window exceeded for $service - stopping recovery');
          servicesToRemove.add(service);
          continue;
        }
      }

      // Check if in cooldown
      if (recoveryState.inCooldown) {
        if (recoveryState.cooldownEndTime != null &&
            now.isAfter(recoveryState.cooldownEndTime!)) {
          // Cooldown ended
          _log('[ServicePriority] $service cooldown ended');
          recoveryState = recoveryState.copyWith(
            inCooldown: false,
            clearCooldownEndTime: true,
          );
          updatedStates[service] = recoveryState;
        } else {
          // Still in cooldown - skip
          continue;
        }
      }

      // Check if service is still enabled
      if (!state.enabledServices.contains(service)) {
        _log(
            '[ServicePriority] $service no longer enabled - stopping recovery');
        servicesToRemove.add(service);
        continue;
      }

      // Check if service is still lower priority than current
      // (current service might have changed)
      final currentService = state.currentService;
      if (currentService != null) {
        final serviceIndex = state.configuredOrder.indexOf(service);
        final currentIndex = state.configuredOrder.indexOf(currentService);
        if (serviceIndex >= currentIndex) {
          // No longer higher priority - stop recovery
          _log(
              '[ServicePriority] $service no longer higher priority - stopping recovery');
          servicesToRemove.add(service);
          continue;
        }
      }

      // Ready to probe
      servicesToProbe.add(service);
    }

    // Remove services that no longer need recovery
    for (final service in servicesToRemove) {
      updatedStates.remove(service);
    }

    if (updatedStates.length != state.recoveryStates.length) {
      state = state.copyWith(recoveryStates: updatedStates);
    }

    // Stop timer if no more services
    if (updatedStates.isEmpty) {
      _stopRecoveryTimer();
      return;
    }

    // Probe services (only the highest priority one that needs probing)
    if (servicesToProbe.isNotEmpty && _probeCallback != null) {
      // Sort by priority order and probe highest priority first
      servicesToProbe.sort((a, b) => state.configuredOrder
          .indexOf(a)
          .compareTo(state.configuredOrder.indexOf(b)));

      final serviceToProbe = servicesToProbe.first;
      _log('[ServicePriority] Probing $serviceToProbe for recovery');
      _probeService(serviceToProbe);
    }
  }

  Future<void> _probeService(ServiceType service) async {
    if (_probeCallback == null) {
      _log('[ServicePriority] No probe callback set');
      return;
    }

    try {
      final isHealthy = await _probeCallback!(service);
      if (isHealthy) {
        onServiceRecovered(service);
      } else {
        onRecoveryProbeFailed(service);
      }
    } catch (e) {
      _log('[ServicePriority] Probe error for $service: $e');
      onRecoveryProbeFailed(service);
    }
  }
}

/// Provider for service priority management
final servicePriorityProvider =
    NotifierProvider<ServicePriorityNotifier, ServicePriorityState>(() {
  return ServicePriorityNotifier();
});
