import 'dart:async';

/// Reusable polling helper with in-flight guard.
///
/// Keeps only one async tick in flight at a time and supports enable/disable
/// toggling without duplicating timer ownership logic across platform bridges.
class SonosProgressPoller {
  Timer? _timer;
  bool _inFlight = false;

  bool get isRunning => _timer != null;

  void start({
    required Duration interval,
    required Future<void> Function() onTick,
  }) {
    stop();

    _timer = Timer.periodic(interval, (_) async {
      if (_inFlight) {
        return;
      }

      _inFlight = true;
      try {
        await onTick();
      } finally {
        _inFlight = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _inFlight = false;
  }
}
