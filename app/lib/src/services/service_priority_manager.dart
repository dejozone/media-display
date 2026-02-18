import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/utils/logging.dart';

final _logger = appLogger('ServicePriority');

void _log(String message, {Level level = Level.INFO}) {
  _logger.log(level, message);
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
    final inRecovery = recoveryStates.containsKey(service);
    final awaiting =
        awaitingRecovery.contains(service) && service.isCloudService;
    return status != ServiceStatus.cooldown &&
        status != ServiceStatus.disabled &&
        !isUnhealthy &&
        !awaiting &&
        !inRecovery;
  }

  /// Check availability while ignoring awaiting-recovery flags (used as a last resort).
  bool isServiceAvailableIgnoringAwaiting(ServiceType service) {
    final status = serviceStatuses[service];
    final isUnhealthy = unhealthyServices.contains(service);
    final inRecovery = recoveryStates.containsKey(service);
    return status != ServiceStatus.cooldown &&
        status != ServiceStatus.disabled &&
        !isUnhealthy &&
        !inRecovery;
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

  /// Get the next available service even if it's marked awaiting-recovery (last resort).
  ServiceType? getNextAvailableServiceIgnoringAwaiting() {
    for (final service in effectiveOrder) {
      if (isServiceAvailableIgnoringAwaiting(service)) {
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
  /// NOTE: retry time window enforcement/resets are handled by the notifier
  /// before calling this helper. This method only checks cooldown and interval.
  bool shouldRetryService(ServiceType service, EnvConfig config) {
    final status = serviceStatuses[service];
    if (status != ServiceStatus.cooldown && status != ServiceStatus.standby) {
      return false;
    }

    final cooldownEnd = cooldownEnds[service];
    if (cooldownEnd != null && DateTime.now().isBefore(cooldownEnd)) {
      return false; // Still in cooldown
    }

    final fallbackConfig = _getFallbackConfig(service, config);

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
  // Per-service timers to enforce fallbackTimeThresholdSec even when no new errors arrive
  final Map<ServiceType, Timer?> _fallbackTimers = {};
  // Track whether a service has already used its initial fallback thresholds
  // (error/time). After the first fallback, subsequent retries should use only
  // retry interval/cooldown/window and fallback immediately on any error.
  final Map<ServiceType, bool> _fallbackThresholdConsumed = <ServiceType, bool>{
    for (final ServiceType s in ServiceType.values) s: false,
  };
  ServiceProbeCallback? _probeCallback;

  EnvConfig get _config => ref.read(envConfigProvider);

  void _resetFallbackThresholdFlags() {
    for (final ServiceType s in _fallbackThresholdConsumed.keys) {
      _fallbackThresholdConsumed[s] = false;
    }
  }

  bool _clientRecoveryEnabled(ServiceType service) {
    final interval = _config.getFallbackConfig(service).retryIntervalSec;
    return interval > 0;
  }

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
      _cancelAllFallbackTimers();
    });

    _resetFallbackThresholdFlags();

    _log('Configured priority order (${config.platformMode.label}): '
        '${config.priorityOrderOfServices}');

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
    bool nativeSonosSupported = true,
    Set<ServiceType>? unhealthyServices,
  }) {
    final enabled = <ServiceType>{};
    final previouslyEnabled = Set<ServiceType>.from(state.enabledServices);

    // Each service has its own requirements from user settings
    for (final service in ServiceType.values) {
      if (!state.configuredOrder.contains(service)) {
        continue; // Skip services not present in configured priority order
      }
      if (service.isNativeSonos && !nativeSonosSupported) {
        continue; // Skip enabling native bridge when platform does not support it
      }
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
    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    final newLastRetries =
        Map<ServiceType, DateTime?>.from(state.lastRetryAttempts);
    for (final service in ServiceType.values) {
      if (!enabled.contains(service)) {
        newStatuses[service] = ServiceStatus.disabled;
      } else if (newStatuses[service] == ServiceStatus.disabled) {
        // Newly re-enabled: reset error/retry state and fallback thresholds
        newStatuses[service] = ServiceStatus.standby;
        newErrors[service] = 0;
        newCooldowns[service] = null;
        newRetryWindows[service] = null;
        newLastRetries[service] = null;
        _fallbackThresholdConsumed[service] = false;
      }
    }

    state = state.copyWith(
      enabledServices: enabled,
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      cooldownEnds: newCooldowns,
      retryWindowStarts: newRetryWindows,
      lastRetryAttempts: newLastRetries,
    );

    // If a service just became disabled, stop any recovery tracking for it
    final newlyDisabled = previouslyEnabled.difference(enabled);
    if (newlyDisabled.isNotEmpty && state.recoveryStates.isNotEmpty) {
      final newRecoveryStates =
          Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
      var recoveryChanged = false;
      for (final svc in newlyDisabled) {
        if (newRecoveryStates.remove(svc) != null) {
          recoveryChanged = true;
          _log('Stopping recovery for $svc (service disabled)');
        }
      }
      if (recoveryChanged) {
        state = state.copyWith(recoveryStates: newRecoveryStates);
        if (newRecoveryStates.isEmpty) {
          _stopRecoveryTimer();
        }
      }
    }

    _log(
        'Updated enabled services: $enabled (spotify=$spotifyEnabled, sonos=$sonosEnabled)');

    // If current service is now disabled, switch to next available
    final currentService = state.currentService;

    if (currentService != null && !enabled.contains(currentService)) {
      _log(
          'Current service $currentService is disabled, finding next available');
      // Try normal availability first.
      var next = state.getNextAvailableService();
      // If nothing is available (e.g., cooldown/awaiting-recovery), reset the
      // highest-priority enabled service to standby so it can be retried now.
      if (next == null) {
        final candidate = _firstEnabledService();
        if (candidate != null) {
          _log(
              'No available service due to cooldown/recovery; resetting $candidate to standby for retry');
          _makeServiceAvailable(candidate);
          next = state.getNextAvailableService();
        }
      }

      _log('Next available service: $next');
      if (next != null) {
        activateService(next);
      } else {
        _log('No next service available, clearing current');
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
              'Higher-priority service $nextAvailable is now available (was on $currentService)');
          activateService(nextAvailable);
        } else if (isHigherPriority && isUnhealthy) {
          _log(
              'Higher-priority service $nextAvailable is enabled but unhealthy - staying on $currentService');
        }
      }
    }
  }

  /// Update the set of unhealthy services
  /// Called by the orchestrator when service health changes
  void updateUnhealthyServices(Set<ServiceType> unhealthy) {
    if (!setEquals(state.unhealthyServices, unhealthy)) {
      state = state.copyWith(unhealthyServices: unhealthy);
    }
  }

  // Force a service out of cooldown/recovery so it can be retried immediately.
  void _makeServiceAvailable(ServiceType service) {
    if (!state.enabledServices.contains(service)) return;

    final statuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    final errors = Map<ServiceType, int>.from(state.errorCounts);
    final cooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    final retryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    final lastRetries =
        Map<ServiceType, DateTime?>.from(state.lastRetryAttempts);

    statuses[service] = ServiceStatus.standby;
    errors[service] = 0;
    cooldowns[service] = null;
    retryWindows[service] = null;
    lastRetries[service] = null;
    _fallbackThresholdConsumed[service] = false;
    _cancelFallbackTimer(service);

    final awaiting = Set<ServiceType>.from(state.awaitingRecovery)
      ..remove(service);
    final recovery =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates)
          ..remove(service);

    state = state.copyWith(
      serviceStatuses: statuses,
      errorCounts: errors,
      cooldownEnds: cooldowns,
      retryWindowStarts: retryWindows,
      lastRetryAttempts: lastRetries,
      awaitingRecovery: awaiting,
      recoveryStates: recovery,
    );
  }

  ServiceType? _firstEnabledService() {
    for (final service in state.configuredOrder) {
      if (state.enabledServices.contains(service)) return service;
    }
    return null;
  }

  /// Mark a cloud service as awaiting server-side recovery to avoid churn
  /// while backend reports failures. Cleared when a healthy status is received.
  void markAwaitingRecovery(ServiceType service) {
    if (!service.isCloudService) return;
    if (state.awaitingRecovery.contains(service)) return;

    final awaiting = Set<ServiceType>.from(state.awaitingRecovery)
      ..add(service);
    state = state.copyWith(awaitingRecovery: awaiting);
    _log('Marked $service as awaiting server recovery');
  }

  /// Activate a specific service
  void activateService(ServiceType service) {
    if (!state.enabledServices.contains(service)) {
      _log('Cannot activate disabled service: $service');
      return;
    }

    // Do not activate a service that is in cooldown or active recovery to avoid
    // immediate churn/loops when it was just failed or is being probed.
    final status = state.serviceStatuses[service];
    final inRecovery = state.recoveryStates.containsKey(service);
    if (status == ServiceStatus.cooldown || inRecovery) {
      _log(
          'Skipping activation of $service (status=$status, inRecovery=$inRecovery)');
      return;
    }

    _log(
        'Activating $service (current=${state.currentService}, enabled=${state.enabledServices})');

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);

    // Deactivate current service
    if (state.currentService != null && state.currentService != service) {
      final current = state.currentService!;
      final currentStatus = newStatuses[current];
      // Preserve cooldown/disabled states when switching so we don't
      // immediately re-enable a service that just failed.
      if (currentStatus != ServiceStatus.cooldown &&
          currentStatus != ServiceStatus.disabled) {
        newStatuses[current] = ServiceStatus.standby;
      }
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
      _log('Cannot switch to disabled service: $service');
      return;
    }

    if (state.currentService == service) {
      _log('Already on service: $service');
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

    _log('Switched to service: $service');

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

    // After the first successful activation, fallback thresholds should no
    // longer be reused on subsequent retries.
    if (_fallbackThresholdConsumed[service] != true) {
      _fallbackThresholdConsumed[service] = true;
    }

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    newErrors[service] = 0;

    _cancelFallbackTimer(service);

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
  void reportError(ServiceType service, {bool is401 = false, Object? error}) {
    // 401 errors should trigger token refresh, not fallback
    if (is401) {
      _log('401 error on $service - triggering token refresh, not fallback');
      return;
    }

    // If cloud service is already marked awaiting recovery, only ignore errors
    // when it is NOT the active service. When it's the active service we still
    // need to count errors so we can fall back to the next priority service.
    if (service.isCloudService && state.awaitingRecovery.contains(service)) {
      // Already waiting for backend recovery; suppress further error counting
      // to avoid inflating thresholds and log noise.
      return;
    }

    final fallbackConfig = _config.getFallbackConfig(service);
    final usingFallbackThresholds =
        _fallbackThresholdConsumed[service] != true; // only on first attempt

    final isPrimary = state.effectiveOrder.isNotEmpty &&
        state.effectiveOrder.first == service;
    // When running on a fallback (non-primary) service during the initial
    // attempt, cap the threshold to 3 so we move down the priority list instead
    // of lingering on repeated failures. After the first fallback has occurred,
    // we bypass thresholds entirely and fallback on the first error.
    final fallbackThreshold = (!isPrimary && state.currentService == service)
        ? fallbackConfig.errorThreshold.clamp(1, 3).toInt()
        : fallbackConfig.errorThreshold;
    final effectiveThreshold = usingFallbackThresholds ? fallbackThreshold : 1;

    if (!fallbackConfig.onError) {
      _log('Fallback on error disabled for $service');
      return;
    }

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final currentCount = newErrors[service] ?? 0;
    final nextCount = currentCount + 1;
    newErrors[service] = nextCount;

    // Anchor the window to the first error in the current streak. Do NOT reset
    // on subsequent errors so the time threshold applies to the full set of
    // attempts (e.g., 3 errors must land within 10s total).
    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    final now = DateTime.now();
    final windowStart = (currentCount == 0)
        ? now
        : (newRetryWindows[service] ?? now); // fallback to now if missing
    newRetryWindows[service] = windowStart;

    // Fallback time threshold only applies on the first attempt; retries
    // should fallback immediately on error without waiting for a time window.
    final timeThreshold =
        usingFallbackThresholds ? fallbackConfig.fallbackTimeThresholdSec : 0;
    final elapsedSinceFirstError = now.difference(windowStart).inSeconds;

    // Start/refresh a timer that will enforce the total window even if no
    // additional errors arrive. Only start on the first error in the streak.
    if (currentCount == 0 && timeThreshold > 0) {
      _cancelFallbackTimer(service);
      _fallbackTimers[service] = Timer(Duration(seconds: timeThreshold), () {
        _handleFallbackWindowExpiry(service, windowStart);
      });
    }

    // Treat fallbackTimeThresholdSec as the maximum window to accumulate
    // errorThreshold samples. Whichever happens first (count reached OR window
    // elapsed) triggers fallback.
    final windowExpired =
        timeThreshold > 0 && elapsedSinceFirstError >= timeThreshold;
    final countReached = nextCount >= effectiveThreshold;

    final thresholdForLog =
        usingFallbackThresholds ? fallbackThreshold : effectiveThreshold;
    final errDetail = error != null ? ' err=${_shortError(error)}' : '';
    _log(
      'Error on $service '
      '(${newErrors[service]}/$thresholdForLog toward FALLBACK_ERROR_THRESHOLD=${fallbackConfig.errorThreshold})$errDetail',
    );

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);

    // For cloud-hosted services, immediately enter awaiting-recovery state to
    // avoid config churn while the server is still unhealthy. Recovery will be
    // cleared when a healthy status is received.
    if (service.isCloudService && !state.awaitingRecovery.contains(service)) {
      final awaiting = Set<ServiceType>.from(state.awaitingRecovery)
        ..add(service);
      state = state.copyWith(awaitingRecovery: awaiting);
      _log('Marked $service as awaiting server recovery');
    }

    final thresholdReached = countReached || windowExpired;

    if (thresholdReached) {
      _cancelFallbackTimer(service);
      if (windowExpired && !countReached) {
        _log(
            '$service fallback window expired after ${elapsedSinceFirstError}s before reaching errorThreshold=${fallbackConfig.errorThreshold}');
      }
      // Mark that we've consumed the initial fallback thresholds for this service
      // so future retries use retry-only behavior (immediate fallback on error).
      _fallbackThresholdConsumed[service] = true;
      // Threshold reached (by count or time) - enter cooldown and trigger fallback
      // final reason = newErrors[service]! >= effectiveThreshold
      //     ? 'error-threshold'
      //     : 'time-threshold';
      // _log(
      //     'Threshold reached for $service ($reason) - entering cooldown');

      newStatuses[service] = ServiceStatus.cooldown;

      final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
      newCooldowns[service] = DateTime.now().add(
        Duration(seconds: fallbackConfig.retryCooldownSec),
      );

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
        retryWindowStarts: newRetryWindows,
      );
    }
  }

  void _handleFallbackWindowExpiry(ServiceType service, DateTime windowStart) {
    if (_fallbackThresholdConsumed[service] == true) {
      return; // fallback window only applies on first attempt
    }
    final fallbackConfig = _config.getFallbackConfig(service);

    // If window start changed or service already in cooldown/disabled, ignore.
    final trackedStart = state.retryWindowStarts[service];
    if (trackedStart == null || trackedStart.isAfter(windowStart)) return;
    final status = state.serviceStatuses[service];
    if (status == ServiceStatus.cooldown || status == ServiceStatus.disabled) {
      return;
    }

    // Enter cooldown and trigger fallback as if time threshold was reached.
    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses)
          ..[service] = ServiceStatus.cooldown;
    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds)
      ..[service] = DateTime.now().add(
        Duration(seconds: fallbackConfig.retryCooldownSec),
      );

    // Keep existing error counts/window; we only need to move to cooldown.
    state = state.copyWith(
      serviceStatuses: newStatuses,
      cooldownEnds: newCooldowns,
    );

    // For cloud services, ensure awaiting-recovery is set.
    if (service.isCloudService && !state.awaitingRecovery.contains(service)) {
      final awaiting = Set<ServiceType>.from(state.awaitingRecovery)
        ..add(service);
      state = state.copyWith(awaitingRecovery: awaiting);
    }

    _log(
        '$service fallback window expired after ${fallbackConfig.fallbackTimeThresholdSec}s (timer)');
    _triggerFallback(service);
  }

  void _cancelFallbackTimer(ServiceType service) {
    _fallbackTimers[service]?.cancel();
    _fallbackTimers.remove(service);
  }

  void _cancelAllFallbackTimers() {
    for (final t in _fallbackTimers.values) {
      t?.cancel();
    }
    _fallbackTimers.clear();
  }

  /// Report a timeout from a service
  void reportTimeout(ServiceType service) {
    reportError(service);
  }

  void _triggerFallback(ServiceType failedService) {
    // Once a service falls back, its initial fallback thresholds are considered consumed
    // so future retries use retry-only behavior.
    _fallbackThresholdConsumed[failedService] = true;

    // Prefer the next available service AFTER the failed one to avoid bouncing
    // back to higher-priority services that were already checked/idle.
    final next = state.getNextAvailableServiceAfter(failedService) ??
        state.getNextAvailableService();

    if (next != null && next != failedService) {
      // _log('Falling back from $failedService to $next');
      activateService(next);
      _startRetryTimer(failedService);

      // Start recovery monitoring for the failed service if it's higher priority
      startRecovery(failedService);
    } else {
      // As a last resort, allow a service that's awaiting-recovery (but not disabled/cooldown)
      final lastResort = state.getNextAvailableServiceIgnoringAwaiting();
      if (lastResort != null && lastResort != failedService) {
        _log(
            'No standard fallback from $failedService; using awaiting-recovery service $lastResort');
        activateService(lastResort);
        _startRetryTimer(failedService);
        startRecovery(failedService);
      } else {
        _log('No fallback available from $failedService');
        // All services unavailable - stay on current and retry later
        _startRetryTimer(failedService);
        // Even without a fallback target, begin recovery so probes can bring it back
        startRecovery(failedService);
      }
    }
  }

  void _startRetryTimer(ServiceType serviceToRetry) {
    _retryTimer?.cancel();

    final fallbackConfig = _config.getFallbackConfig(serviceToRetry);

    // If retry interval is 0/negative, skip starting the timer to avoid
    // tight retry loops (e.g., when client-side retry is disabled).
    if (fallbackConfig.retryIntervalSec <= 0) {
      _log('Skipping retry timer for $serviceToRetry (retryIntervalSec<=0)');
      return;
    }

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
      // _log(
      //     'Awaiting recovery for ${state.currentService}; skipping retry');
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
    final current = state.currentService;
    final currentIdx =
        current != null ? state.configuredOrder.indexOf(current) : -1;

    var attempted = false;

    for (final service in state.effectiveOrder) {
      // Only retry services that are HIGHER priority than the current one.
      if (currentIdx >= 0) {
        final serviceIdx = state.configuredOrder.indexOf(service);
        if (serviceIdx >= currentIdx) {
          continue;
        }
      }

      if (state.awaitingRecovery.contains(service) && service.isCloudService) {
        // Wait for server-side health recovery for cloud services
        continue;
      }

      // If a service is already in active recovery probing (e.g., directSpotify),
      // let the recovery loop promote it on success instead of force-switching
      // here. This avoids churn away from a healthy fallback while probes run.
      if (state.recoveryStates.containsKey(service)) {
        continue;
      }

      if (service == state.currentService) continue;

      // If retry time window is exhausted, enforce cooldown and restart window
      final retryWindowStart = state.retryWindowStarts[service];
      final fallbackConfig = _config.getFallbackConfig(service);
      final maxRetryTime = fallbackConfig.retryTimeSec;
      if (maxRetryTime > 0 && retryWindowStart != null) {
        final elapsed = DateTime.now().difference(retryWindowStart).inSeconds;
        if (elapsed >= maxRetryTime) {
          // Enter cooldown and restart the window
          final newCooldowns =
              Map<ServiceType, DateTime?>.from(state.cooldownEnds);
          newCooldowns[service] = DateTime.now()
              .add(Duration(seconds: fallbackConfig.retryCooldownSec));

          final newRetryWindows =
              Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
          newRetryWindows[service] = DateTime.now();

          final newStatuses =
              Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
          newStatuses[service] = ServiceStatus.cooldown;

          state = state.copyWith(
            cooldownEnds: newCooldowns,
            retryWindowStarts: newRetryWindows,
            serviceStatuses: newStatuses,
          );
          continue;
        }
      }

      // Initialize retry window start if missing
      if (state.retryWindowStarts[service] == null) {
        final newRetryWindows =
            Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
        newRetryWindows[service] = DateTime.now();
        state = state.copyWith(retryWindowStarts: newRetryWindows);
      }

      if (state.shouldRetryService(service, _config)) {
        _log('Attempting retry of $service');

        attempted = true;

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

    // If nothing is eligible to retry right now, simply wait for the next tick
    // (e.g., cooldown not elapsed yet). Avoid spamming the log.
    if (!attempted) {
      return;
    }
  }

  /// Manually request activation of the first available service
  /// Returns the activated service, or null if none available
  ServiceType? activateFirstAvailable() {
    final service = state.getNextAvailableService();
    _log('activateFirstAvailable resolved to $service');
    if (service != null) {
      activateService(service);
    }
    return service;
  }

  /// Activate the highest-priority available service.
  /// If [force] is false and we're already on that service, do nothing.
  ServiceType? _activateHighestPriorityAvailable({bool force = false}) {
    _log(
        'Evaluating highest-priority service (force=$force, current=${state.currentService})');
    final service = state.getNextAvailableService();
    if (service == null) {
      _log('No available service to activate');
      return null;
    }

    if (!force && state.currentService == service) {
      _log('Already on highest-priority service: $service');
      return service;
    }

    activateService(service);
    return service;
  }

  /// Called when WebSocket successfully reconnects
  /// Resets cooldowns for cloud services so they can be retried
  /// and re-evaluates if we should switch back to a higher-priority cloud service
  void onWebSocketReconnected() {
    _log('WebSocket reconnected - re-evaluating cloud services');

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
          _log('Resetting $service from $status to standby');
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
      _log('Clearing awaiting-recovery flags on reconnect');
      clearedAwaiting = <ServiceType>{};
    }

    state = state.copyWith(
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      cooldownEnds: newCooldowns,
      retryWindowStarts: newRetryWindows,
      awaitingRecovery: clearedAwaiting,
    );

    // After reconnect, force a fresh initial activation cycle just like first
    // login. This resets the current service so we re-evaluate the configured
    // priority order (even if a fallback like directSpotify was active).
    _restartInitialActivationAfterReconnect();
  }

  /// Reset current service and transition state, then activate the first
  /// available service using the priority order (like a cold start).
  void _restartInitialActivationAfterReconnect() {
    // Stop any retry/recovery timers so the fresh start isn't racing timers
    _retryTimer?.cancel();
    _retryTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _cancelAllFallbackTimers();

    // Reset per-service fallback thresholds so post-reconnect errors use the
    // configured thresholds (e.g., 1/3 → 3/3) instead of immediate 1/1.
    _resetFallbackThresholdFlags();

    // Reset statuses for enabled services back to standby (keep disabled as-is)
    final resetStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    for (final entry in resetStatuses.entries.toList()) {
      if (entry.value != ServiceStatus.disabled) {
        resetStatuses[entry.key] = ServiceStatus.standby;
      }
    }

    // Clear error/cooldown/retry bookkeeping so retries don't immediately fire
    final resetErrors = <ServiceType, int>{
      for (final s in ServiceType.values) s: 0,
    };
    final resetCooldowns = <ServiceType, DateTime?>{
      for (final s in ServiceType.values) s: null,
    };
    final resetRetryWindows = <ServiceType, DateTime?>{
      for (final s in ServiceType.values) s: null,
    };
    final resetLastRetries = <ServiceType, DateTime?>{
      for (final s in ServiceType.values) s: null,
    };

    state = state.copyWith(
      serviceStatuses: resetStatuses,
      errorCounts: resetErrors,
      cooldownEnds: resetCooldowns,
      retryWindowStarts: resetRetryWindows,
      lastRetryAttempts: resetLastRetries,
      awaitingRecovery: const {},
      // Clear unhealthy flags so reconnect can re-evaluate full priority order
      // instead of sticking to a previous fallback (e.g., directSpotify).
      unhealthyServices: const {},
      recoveryStates: const {},
      isTransitioning: false,
      clearTransitionStartTime: true,
      clearLastDataTime: true,
      // Ensure current/previous are cleared so activation emits and orchestrator
      // re-sends config after reconnect.
      clearCurrentService: true,
      clearPreviousService: true,
    );

    _resetFallbackThresholdFlags();

    _log('Re-running initial activation after reconnect');
    _activateHighestPriorityAvailable(force: true);
    if (state.currentService == _getFirstEnabledService()) {
      _cancelRetryTimer();
    }
  }

  /// Public hook to re-run the initial activation flow (used on resets)
  void restartInitialActivation() {
    _log('Re-running initial activation (explicit restart)');
    _restartInitialActivationAfterReconnect();
  }

  /// Reset all services to initial state
  void reset() {
    _log('Resetting priority state to initial');

    _retryTimer?.cancel();
    _retryTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _cancelAllFallbackTimers();

    // Reset statuses for enabled services back to standby (keep disabled as-is)
    final resetStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    for (final entry in resetStatuses.entries.toList()) {
      if (entry.value != ServiceStatus.disabled) {
        resetStatuses[entry.key] = ServiceStatus.standby;
      }
    }

    // Clear all bookkeeping so retries/fallbacks start fresh
    final resetErrors = <ServiceType, int>{
      for (final s in ServiceType.values) s: 0,
    };
    final resetCooldowns = <ServiceType, DateTime?>{
      for (final s in ServiceType.values) s: null,
    };
    final resetRetryWindows = <ServiceType, DateTime?>{
      for (final s in ServiceType.values) s: null,
    };
    final resetLastRetries = <ServiceType, DateTime?>{
      for (final s in ServiceType.values) s: null,
    };

    state = state.copyWith(
      serviceStatuses: resetStatuses,
      errorCounts: resetErrors,
      cooldownEnds: resetCooldowns,
      retryWindowStarts: resetRetryWindows,
      lastRetryAttempts: resetLastRetries,
      awaitingRecovery: const {},
      unhealthyServices: const {},
      recoveryStates: const {},
      isTransitioning: false,
      clearTransitionStartTime: true,
      clearLastDataTime: true,
      clearCurrentService: true,
      clearPreviousService: true,
    );

    _resetFallbackThresholdFlags();

    _resetFallbackThresholdFlags();
  }

  /// Stop all retry timers
  void stopRetryTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelAllFallbackTimers();
  }

  /// Stop all retry/recovery activity for services below the active one.
  /// Used when a higher-priority service is confirmed playing so we don't churn.
  void quiesceLowerPriorityServices(ServiceType activeService) {
    final activeIndex = state.configuredOrder.indexOf(activeService);
    if (activeIndex < 0) {
      return;
    }

    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    final newLastRetries =
        Map<ServiceType, DateTime?>.from(state.lastRetryAttempts);
    final newAwaiting = Set<ServiceType>.from(state.awaitingRecovery);
    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);

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
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  // ============================================================
  // Service Recovery Methods
  // ============================================================

  /// Start recovery monitoring for a failed service that is higher priority than current
  /// Called when a service fails and we fall back to a lower-priority service
  /// NOTE: Client-side recovery is supported for directSpotify and nativeLocalSonos.
  /// Cloud services (cloudSpotify, localSonos) rely on WebSocket/server health.
  void startRecovery(ServiceType failedService) {
    final isCloud = failedService.isCloudService;

    // Respect per-service toggle: interval <= 0 means rely solely on server health
    if (isCloud && !_clientRecoveryEnabled(failedService)) {
      _log(
          'Skipping client-side recovery for $failedService (retry interval <= 0; waiting for server health)');
      return;
    }

    // Client-side recovery supported for direct Spotify and native Sonos
    if (!isCloud &&
        failedService != ServiceType.directSpotify &&
        failedService != ServiceType.nativeLocalSonos) {
      _log('Skipping client-side recovery for $failedService (not supported)');
      return;
    }

    final fallbackConfig = _config.getFallbackConfig(failedService);
    _log(
        'Starting recovery for $failedService (interval=${fallbackConfig.retryIntervalSec}s, '
        'timeWindow=${fallbackConfig.retryTimeSec}s, cooldown=${fallbackConfig.retryCooldownSec}s)');

    // Recovery paths should not reuse initial fallback thresholds; ensure they
    // are marked consumed once recovery begins.
    _fallbackThresholdConsumed[failedService] = true;

    final currentService = state.currentService;
    final onlyEnabledFailed = state.effectiveOrder.length == 1 &&
        state.effectiveOrder.first == failedService;

    // If nothing is currently active but this is the only enabled service,
    // allow recovery so probes can bring it back.
    if (currentService == null && !onlyEnabledFailed) return;

    // Check if failed service is higher priority than current, unless it's the only option
    final failedIndex = state.configuredOrder.indexOf(failedService);
    final currentIndex = currentService != null
        ? state.configuredOrder.indexOf(currentService)
        : -1;

    if (failedIndex < 0 || (currentIndex < 0 && !onlyEnabledFailed)) return;
    if (currentService != null &&
        failedIndex >= currentIndex &&
        !onlyEnabledFailed) {
      // Failed service is lower priority or same; skip unless it's the only enabled service
      return;
    }

    // Check if already in recovery
    if (state.recoveryStates.containsKey(failedService)) {
      _log('Recovery already active for $failedService');
      return;
    }

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

    // Kick an immediate probe when entering recovery so single-service paths
    // don't wait for the first timer tick.
    _probeService(failedService);
  }

  /// Stop recovery monitoring for a service
  void stopRecovery(ServiceType service) {
    if (!state.recoveryStates.containsKey(service)) return;

    _log('Stopping recovery for $service');

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

    _log('Clearing all recovery states');
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

    _log('Service $service recovered');

    // Remove from recovery states
    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    newRecoveryStates.remove(service);

    // Clear awaiting recovery flag
    final newAwaiting = Set<ServiceType>.from(state.awaitingRecovery)
      ..remove(service);

    // Reset service status/bookkeeping so activation is not blocked by stale
    // cooldowns or retry windows.
    final newStatuses =
        Map<ServiceType, ServiceStatus>.from(state.serviceStatuses);
    newStatuses[service] = ServiceStatus.standby;

    final newErrors = Map<ServiceType, int>.from(state.errorCounts);
    newErrors[service] = 0;

    final newCooldowns = Map<ServiceType, DateTime?>.from(state.cooldownEnds);
    newCooldowns[service] = null;

    final newRetryWindows =
        Map<ServiceType, DateTime?>.from(state.retryWindowStarts);
    newRetryWindows[service] = null;

    final newLastRetries =
        Map<ServiceType, DateTime?>.from(state.lastRetryAttempts);
    newLastRetries[service] = null;

    state = state.copyWith(
      recoveryStates: newRecoveryStates,
      serviceStatuses: newStatuses,
      errorCounts: newErrors,
      cooldownEnds: newCooldowns,
      retryWindowStarts: newRetryWindows,
      lastRetryAttempts: newLastRetries,
      awaitingRecovery: newAwaiting,
    );

    // Promote recovered service when it is enabled and either (a) current is
    // null, (b) it is the highest-priority enabled service, or (c) it is
    // higher priority than the current service.
    final highestEnabled = _getFirstEnabledService();
    final current = state.currentService;
    final currentStatus = state.serviceStatuses[service];
    final shouldPromote =
        (current == null && state.enabledServices.contains(service)) ||
            (highestEnabled == service && current != service) ||
            (serviceIndex >= 0 && serviceIndex < currentIndex) ||
            (current == service && currentStatus != ServiceStatus.active);

    if (shouldPromote && state.enabledServices.contains(service)) {
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
  void onRecoveryProbeFailed(ServiceType service, {Object? error}) {
    final recoveryState = state.recoveryStates[service];
    if (recoveryState == null) return;

    // Failed probe: count it and stamp time, but do not enter cooldown yet.
    // Cooldown should occur only when the retry time window is exhausted
    // (_onRecoveryTimerTick handles that), so we can continue probing at the
    // configured retry interval within the window.
    final newFailures = recoveryState.consecutiveFailures + 1;

    final errDetail = error != null ? ' err=${_shortError(error)}' : '';
    _log(
        'Recovery probe failed for $service (failures=$newFailures)$errDetail');
    final updatedState = recoveryState.copyWith(
      consecutiveFailures: newFailures,
      lastProbeTime: DateTime.now(),
    );

    final newRecoveryStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    newRecoveryStates[service] = updatedState;

    state = state.copyWith(recoveryStates: newRecoveryStates);
  }

  void _startRecoveryTimer() {
    // Determine the fastest probe interval among services under recovery
    final interval = _computeRecoveryTimerIntervalSec();
    if (interval == null) {
      _log('Recovery timer not started (no eligible recovery intervals)');
      return;
    }

    // Always restart to honor updated intervals
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer.periodic(
      Duration(seconds: interval),
      (_) => _onRecoveryTimerTick(),
    );
  }

  int? _computeRecoveryTimerIntervalSec() {
    if (state.recoveryStates.isEmpty) return null;

    final intervals = state.recoveryStates.keys
        .map((s) => _config.getFallbackConfig(s).retryIntervalSec)
        .where((v) => v > 0)
        .toList();

    if (intervals.isEmpty) return null;
    final minInterval = intervals.reduce((a, b) => a < b ? a : b);
    return minInterval.clamp(1, minInterval);
  }

  void _stopRecoveryTimer() {
    if (_recoveryTimer != null) {
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
    }
  }

  void _onRecoveryTimerTick() {
    final servicesToProbe = <ServiceType>[];
    final servicesToRemove = <ServiceType>[];
    final updatedStates =
        Map<ServiceType, ServiceRecoveryState>.from(state.recoveryStates);
    var recoveryChanged = false;
    final now = DateTime.now();

    for (final entry in state.recoveryStates.entries) {
      final service = entry.key;
      var recoveryState = entry.value;

      // Get service-specific config
      final fallbackConfig = _config.getFallbackConfig(service);
      final maxWindow = fallbackConfig.retryTimeSec;

      // If we're in cooldown, wait until it ends before evaluating window timing.
      if (recoveryState.inCooldown) {
        if (recoveryState.cooldownEndTime != null &&
            now.isAfter(recoveryState.cooldownEndTime!)) {
          // Cooldown ended
          recoveryState = recoveryState.copyWith(
            inCooldown: false,
            clearCooldownEndTime: true,
            windowStartTime: DateTime.now(),
          );
          updatedStates[service] = recoveryState;
          recoveryChanged = true;
        } else {
          // Still in cooldown - skip further processing for this service
          continue;
        }
      }

      // If the recovery window is exhausted, enter cooldown and restart window
      // after cooldown instead of abandoning recovery.
      if (maxWindow > 0) {
        final windowElapsed =
            now.difference(recoveryState.windowStartTime).inSeconds;
        if (windowElapsed >= maxWindow) {
          final cooldownUntil = DateTime.now()
              .add(Duration(seconds: fallbackConfig.retryCooldownSec));
          recoveryState = recoveryState.copyWith(
            inCooldown: true,
            cooldownEndTime: cooldownUntil,
            windowStartTime: DateTime.now(),
          );
          updatedStates[service] = recoveryState;
          recoveryChanged = true;
          _log(
              'Recovery window exhausted for $service after ${windowElapsed}s; cooling down for ${fallbackConfig.retryCooldownSec}s');
          continue;
        }
      }

      // Check if service is still enabled
      if (!state.enabledServices.contains(service)) {
        _log('$service no longer enabled - stopping recovery');
        servicesToRemove.add(service);
        recoveryChanged = true;
        continue;
      }

      // Check if service is still lower priority than current
      // (current service might have changed)
      final currentService = state.currentService;
      final onlyEnabledService = state.effectiveOrder.length == 1 &&
          state.effectiveOrder.first == service;
      if (currentService != null && !onlyEnabledService) {
        final serviceIndex = state.configuredOrder.indexOf(service);
        final currentIndex = state.configuredOrder.indexOf(currentService);
        if (serviceIndex >= currentIndex) {
          // No longer higher priority - stop recovery
          servicesToRemove.add(service);
          recoveryChanged = true;
          continue;
        }
      }

      // Respect per-service probe interval
      final intervalSec = fallbackConfig.retryIntervalSec;
      final lastProbe = recoveryState.lastProbeTime;
      if (intervalSec <= 0) {
        continue; // Should not happen because we gate when adding, but defensive
      }
      if (lastProbe != null &&
          now.difference(lastProbe).inSeconds < intervalSec) {
        continue; // Not yet time to probe
      }

      // Ready to probe
      servicesToProbe.add(service);
    }

    // Remove services that no longer need recovery
    for (final service in servicesToRemove) {
      updatedStates.remove(service);
    }

    if (recoveryChanged ||
        updatedStates.length != state.recoveryStates.length) {
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
      // Stamp last probe time to enforce interval, even if probe is skipped/async
      final recoveryState = updatedStates[serviceToProbe];
      if (recoveryState != null) {
        updatedStates[serviceToProbe] =
            recoveryState.copyWith(lastProbeTime: DateTime.now());
        state = state.copyWith(recoveryStates: updatedStates);
      }
      _log('Recovery probe due for $serviceToProbe');
      _probeService(serviceToProbe);
    }
  }

  Future<void> _probeService(ServiceType service) async {
    if (_probeCallback == null) {
      _log('No probe callback set');
      return;
    }

    try {
      // _log('Probing $service for recovery');
      final isHealthy = await _probeCallback!(service);
      if (isHealthy) {
        onServiceRecovered(service);
      } else {
        // For cloud services, probes are best-effort requests for server health.
        // Do not penalize failures; await server or future probes to mark healthy.
        if (service.isCloudService) {
          return;
        }
        // _log('Recovery probe failed for $service');
        onRecoveryProbeFailed(service, error: 'probe returned unhealthy');
      }
    } catch (e) {
      _log('Probe error for $service: $e');
      onRecoveryProbeFailed(service, error: e);
    }
  }
}

String _shortError(Object error) {
  final s = error.toString();
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

/// Provider for service priority management
final servicePriorityProvider =
    NotifierProvider<ServicePriorityNotifier, ServicePriorityState>(() {
  return ServicePriorityNotifier();
});
