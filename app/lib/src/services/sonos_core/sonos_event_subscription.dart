import 'dart:async';

import 'package:media_display/src/services/sonos_core/sonos_http_transport.dart';

typedef SonosEventLog = void Function(String message);

class SonosEventSubscription {
  SonosEventSubscription({
    required SonosHttpTransport transport,
    required SonosEventLog log,
    this.onRenewPreconditionFailed,
    Duration renewAfter = const Duration(seconds: 540),
    this.eventPath = '/MediaRenderer/AVTransport/Event',
    this.subscriptionTimeout = 'Second-600',
  })  : _transport = transport,
        _log = log,
        _renewAfter = renewAfter;

  final SonosHttpTransport _transport;
  final SonosEventLog _log;
  final Future<void> Function(String host)? onRenewPreconditionFailed;
  final Duration _renewAfter;
  final String eventPath;
  final String subscriptionTimeout;

  String? _sid;
  String? _host;
  Timer? _renewTimer;

  String? get sid => _sid;

  Future<void> subscribe({
    required String host,
    required String callbackUrl,
    required Duration timeout,
  }) async {
    if (_sid != null) {
      _log('Already subscribed sid=$_sid, skipping subscribe');
      return;
    }

    final response = await _transport.send(
      SonosHttpRequest(
        url: Uri.parse('http://$host:1400$eventPath'),
        method: 'SUBSCRIBE',
        headers: {
          'CALLBACK': '<$callbackUrl>',
          'NT': 'upnp:event',
          'TIMEOUT': subscriptionTimeout,
        },
        timeout: timeout,
      ),
    );

    final sid = response.headers['sid'];
    if (sid == null || sid.isEmpty) {
      throw StateError('Subscription failed: missing SID');
    }

    _sid = sid;
    _host = host;
    _scheduleRenew(timeout);
  }

  Future<void> renew({required Duration timeout}) async {
    final sid = _sid;
    final host = _host;
    if (sid == null || host == null) {
      return;
    }

    final response = await _transport.send(
      SonosHttpRequest(
        url: Uri.parse('http://$host:1400$eventPath'),
        method: 'SUBSCRIBE',
        headers: {
          'SID': sid,
          'TIMEOUT': subscriptionTimeout,
        },
        timeout: timeout,
      ),
    );

    if (response.statusCode == 412) {
      _sid = null;
      throw StateError('renew_precondition_failed');
    }

    _scheduleRenew(timeout);
  }

  Future<void> unsubscribe({required Duration timeout}) async {
    _renewTimer?.cancel();
    _renewTimer = null;

    final sid = _sid;
    final host = _host;
    _sid = null;
    _host = null;

    if (sid == null || host == null) {
      return;
    }

    await _transport.send(
      SonosHttpRequest(
        url: Uri.parse('http://$host:1400$eventPath'),
        method: 'UNSUBSCRIBE',
        headers: {'SID': sid},
        timeout: timeout,
      ),
    );
  }

  Future<void> reset({required Duration timeout}) async {
    try {
      await unsubscribe(timeout: timeout);
    } catch (_) {
      // Best-effort cleanup during reset.
    }
  }

  void _scheduleRenew(Duration timeout) {
    _renewTimer?.cancel();
    _renewTimer = Timer(_renewAfter, () async {
      try {
        await renew(timeout: timeout);
      } catch (e) {
        if (e is StateError && e.message == 'renew_precondition_failed') {
          final host = _host;
          _sid = null;
          if (host != null) {
            _log('Subscription renew returned 412; bridge should resubscribe');
            await onRenewPreconditionFailed?.call(host);
          }
        } else {
          _log('Subscription renew failed: $e');
        }
      }
    });
  }
}
