/// Service health status tracking for the client.
///
/// This module handles service status messages from the backend and tracks
/// the health of each service to enable smart recovery behavior.

import 'package:flutter/foundation.dart';

/// Health status of a service (from backend health checks).
/// Note: Named HealthStatus to avoid conflict with ServiceStatus in service_priority_manager.
enum HealthStatus {
  healthy,
  degraded,
  recovering,
  unavailable;

  static HealthStatus fromString(String value) {
    switch (value.toLowerCase()) {
      case 'healthy':
        return HealthStatus.healthy;
      case 'degraded':
        return HealthStatus.degraded;
      case 'recovering':
        return HealthStatus.recovering;
      case 'unavailable':
        return HealthStatus.unavailable;
      default:
        return HealthStatus.unavailable;
    }
  }

  bool get isHealthy => this == HealthStatus.healthy;
  bool get canUse =>
      this == HealthStatus.healthy || this == HealthStatus.degraded;
  bool get shouldFallback =>
      this == HealthStatus.recovering || this == HealthStatus.unavailable;
}

/// Error codes for service health issues.
enum ServiceErrorCode {
  noDevices,
  networkError,
  subscriptionFailed,
  deviceRebooting,
  deviceUpdating,
  coordinatorError,
  authError,
  timeout,
  rateLimited, // Spotify-specific: API rate limit hit
  serverError, // Spotify-specific: 5xx errors
  unknown;

  static ServiceErrorCode fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'no_devices':
        return ServiceErrorCode.noDevices;
      case 'network_error':
        return ServiceErrorCode.networkError;
      case 'subscription_failed':
        return ServiceErrorCode.subscriptionFailed;
      case 'device_rebooting':
        return ServiceErrorCode.deviceRebooting;
      case 'device_updating':
        return ServiceErrorCode.deviceUpdating;
      case 'coordinator_error':
        return ServiceErrorCode.coordinatorError;
      case 'auth_error':
        return ServiceErrorCode.authError;
      case 'timeout':
        return ServiceErrorCode.timeout;
      case 'rate_limited':
        return ServiceErrorCode.rateLimited;
      case 'server_error':
        return ServiceErrorCode.serverError;
      default:
        return ServiceErrorCode.unknown;
    }
  }

  /// Whether this error requires user action (no auto-retry).
  bool get requiresUserAction => this == ServiceErrorCode.authError;
}

/// Immutable state representing the health of a service.
///
/// This class parses standardized service_status messages from the backend.
/// The message structure is consistent for all services (Sonos, Spotify, etc.):
///
/// ```json
/// {
///   "type": "service_status",
///   "provider": "sonos" | "spotify",
///   "status": "healthy" | "degraded" | "recovering" | "unavailable",
///   "error_code": "no_devices" | "network_error" | "rate_limited" | null,
///   "message": "Human readable message" | null,
///   "devices_count": 0,
///   "retry_in_sec": 15,
///   "should_fallback": true | false,
///   "last_healthy_at": 1737987600.123
/// }
/// ```
@immutable
class ServiceHealthState {
  const ServiceHealthState({
    required this.provider,
    this.status = HealthStatus.healthy,
    this.errorCode,
    this.message,
    this.devicesCount = 0,
    this.retryInSec = 0,
    this.shouldFallback = false,
    this.lastHealthyAt,
    this.recoveryAttempts = 0,
    this.nextRetryAt,
  });

  /// The service provider name (e.g., "sonos", "spotify").
  final String provider;

  /// Current health status.
  final HealthStatus status;

  /// Error code if unhealthy (null when healthy).
  final ServiceErrorCode? errorCode;

  /// Human-readable error message (null when healthy).
  final String? message;

  /// Number of devices found (primarily for Sonos; 0 for Spotify).
  final int devicesCount;

  /// Suggested retry time in seconds from the backend.
  final int retryInSec;

  /// Whether the client should fallback to another service.
  final bool shouldFallback;

  /// When the service was last healthy.
  final DateTime? lastHealthyAt;

  /// Client-side tracking: number of recovery attempts made.
  final int recoveryAttempts;

  /// Client-side tracking: when the next retry is scheduled.
  final DateTime? nextRetryAt;

  /// Parse from a service_status message from the backend.
  ///
  /// The message structure is standardized across all services.
  factory ServiceHealthState.fromMessage(Map<String, dynamic> data) {
    final provider = data['provider'] as String? ?? 'unknown';
    final statusStr = data['status'] as String? ?? 'unavailable';
    final errorCodeStr = data['error_code'] as String?;
    final lastHealthyAtNum = data['last_healthy_at'] as num?;

    return ServiceHealthState(
      provider: provider,
      status: HealthStatus.fromString(statusStr),
      errorCode: errorCodeStr != null
          ? ServiceErrorCode.fromString(errorCodeStr)
          : null,
      message: data['message'] as String?,
      devicesCount: (data['devices_count'] as num?)?.toInt() ?? 0,
      retryInSec: (data['retry_in_sec'] as num?)?.toInt() ?? 0,
      shouldFallback: data['should_fallback'] as bool? ?? false,
      lastHealthyAt: lastHealthyAtNum != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (lastHealthyAtNum * 1000).toInt())
          : null,
    );
  }

  /// Create a copy with updated recovery attempt tracking.
  ServiceHealthState withRecoveryAttempt({
    required int attempts,
    required DateTime nextRetry,
  }) {
    return ServiceHealthState(
      provider: provider,
      status: status,
      errorCode: errorCode,
      message: message,
      devicesCount: devicesCount,
      retryInSec: retryInSec,
      shouldFallback: shouldFallback,
      lastHealthyAt: lastHealthyAt,
      recoveryAttempts: attempts,
      nextRetryAt: nextRetry,
    );
  }

  /// Reset to healthy state.
  ServiceHealthState asHealthy({int? devicesCount}) {
    return ServiceHealthState(
      provider: provider,
      status: HealthStatus.healthy,
      devicesCount: devicesCount ?? this.devicesCount,
      lastHealthyAt: DateTime.now(),
      recoveryAttempts: 0,
    );
  }

  /// Whether the service is usable.
  bool get isUsable => status.canUse;

  /// Whether recovery is in progress.
  bool get isRecovering => status == HealthStatus.recovering;

  /// Whether the service is completely unavailable.
  bool get isUnavailable => status == HealthStatus.unavailable;

  /// Calculate effective retry wait time with backoff.
  int getEffectiveRetrySeconds({
    required int minWaitSec,
    required int maxWaitSec,
    required double backoffMultiplier,
  }) {
    if (retryInSec <= 0) return 0;

    // Clamp base retry time
    var waitSec = retryInSec.clamp(minWaitSec, maxWaitSec);

    // Apply backoff for repeated failures
    if (recoveryAttempts > 0 && backoffMultiplier > 1.0) {
      final backoffFactor = _pow(backoffMultiplier, recoveryAttempts);
      waitSec = (waitSec * backoffFactor).toInt().clamp(minWaitSec, maxWaitSec);
    }

    return waitSec;
  }

  /// Simple power function for backoff calculation.
  static double _pow(double base, int exponent) {
    var result = 1.0;
    for (var i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }

  @override
  String toString() {
    return 'ServiceHealthState('
        'provider: $provider, '
        'status: $status, '
        'errorCode: $errorCode, '
        'message: $message, '
        'devicesCount: $devicesCount, '
        'retryInSec: $retryInSec, '
        'shouldFallback: $shouldFallback, '
        'recoveryAttempts: $recoveryAttempts'
        ')';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ServiceHealthState &&
        other.provider == provider &&
        other.status == status &&
        other.errorCode == errorCode &&
        other.message == message &&
        other.devicesCount == devicesCount &&
        other.retryInSec == retryInSec &&
        other.shouldFallback == shouldFallback &&
        other.recoveryAttempts == recoveryAttempts;
  }

  @override
  int get hashCode {
    return Object.hash(
      provider,
      status,
      errorCode,
      message,
      devicesCount,
      retryInSec,
      shouldFallback,
      recoveryAttempts,
    );
  }
}
