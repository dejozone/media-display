import 'package:flutter/foundation.dart';

/// Reusable retry policy for WebSocket (or similar) reconnect attempts.
/// - retry every [interval]
/// - keep retrying for [activeWindow]
/// - then back off for [cooldown]
/// - repeat until [maxTotal] has elapsed from the first failure
class WsRetryPolicy {
  WsRetryPolicy({
    required this.interval,
    required this.activeWindow,
    required this.cooldown,
    required this.maxTotal,
  });

  final Duration interval;
  final Duration activeWindow;
  final Duration cooldown;
  final Duration maxTotal;

  DateTime? _sessionStart;
  DateTime? _cycleStart;
  bool _inCooldown = false;
  int _retryCount = 0;

  /// Whether we're currently in the retry/cooldown cycle
  bool get isRetrying => _sessionStart != null;

  /// Whether we're currently in cooldown period
  bool get inCooldown => _inCooldown;

  /// Number of retries attempted in current session
  int get retryCount => _retryCount;

  /// Returns the delay until the next retry, or null if retries are exhausted.
  Duration? nextDelay() {
    final now = DateTime.now();
    _sessionStart ??= now;

    final sessionElapsed = now.difference(_sessionStart!);
    if (sessionElapsed >= maxTotal) {
      return null;
    }

    _cycleStart ??= now;
    final cycleElapsed = now.difference(_cycleStart!);

    if (cycleElapsed >= activeWindow && !_inCooldown) {
      // Enter cooldown, then restart a fresh cycle after the cooldown elapses.
      _inCooldown = true;
      return cooldown;
    }

    if (_inCooldown) {
      // Cooldown just ended, start fresh cycle
      _inCooldown = false;
      _cycleStart = now;
      _retryCount = 0;
    }

    _retryCount++;
    return interval;
  }

  /// Reset after a successful connection so a future failure starts fresh.
  void reset() {
    _sessionStart = null;
    _cycleStart = null;
    _inCooldown = false;
    _retryCount = 0;
  }

  @visibleForTesting
  DateTime? get sessionStart => _sessionStart;
}
