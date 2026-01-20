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

  /// Returns the delay until the next retry, or null if retries are exhausted.
  Duration? nextDelay() {
    final now = DateTime.now();
    _sessionStart ??= now;
    if (now.difference(_sessionStart!) >= maxTotal) {
      return null;
    }

    _cycleStart ??= now;
    final cycleElapsed = now.difference(_cycleStart!);

    if (cycleElapsed >= activeWindow) {
      // Enter cooldown, then restart a fresh cycle after the cooldown elapses.
      _cycleStart = now.add(cooldown);
      return cooldown;
    }

    return interval;
  }

  /// Reset after a successful connection so a future failure starts fresh.
  void reset() {
    _sessionStart = null;
    _cycleStart = null;
  }

  @visibleForTesting
  DateTime? get sessionStart => _sessionStart;
}
