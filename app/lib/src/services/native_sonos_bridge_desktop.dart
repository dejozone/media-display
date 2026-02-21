import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:media_display/src/services/native_sonos_bridge_stub.dart';
import 'package:media_display/src/services/sonos_core/sonos_control_service.dart';
import 'package:media_display/src/services/sonos_core/sonos_event_subscription.dart';
import 'package:media_display/src/services/sonos_core/sonos_http_transport.dart';
import 'package:media_display/src/services/sonos_core/sonos_http_transport_io.dart';
import 'package:media_display/src/services/sonos_core/sonos_payload_builder.dart';
import 'package:media_display/src/services/sonos_core/sonos_progress_poller.dart';
import 'package:media_display/src/services/sonos_core/sonos_protocol_parser.dart';
import 'package:media_display/src/services/sonos_core/sonos_ssdp_discovery.dart';
import 'package:media_display/src/services/sonos_core/sonos_ssdp_discovery_io.dart';
import 'package:media_display/src/utils/logging.dart';

/// Desktop Sonos bridge (macOS/Linux/Windows) that runs shared Sonos protocol logic.
class NativeSonosBridge {
  NativeSonosBridge({
    SonosHttpTransport? httpTransport,
    SonosSsdpDiscoveryAdapter? discoveryAdapter,
    SonosProtocolParser? protocolParser,
  })  : _logger = appLogger('NativeSonosBridgeDesktop'),
        _httpTransport = httpTransport ?? const SonosHttpTransportIo(),
        _ssdpDiscovery = SonosSsdpDiscovery(
          discoveryAdapter ?? const SonosSsdpDiscoveryIo(),
        ),
        _protocolParser = protocolParser ?? const SonosProtocolParser() {
    _eventSubscription = SonosEventSubscription(
      transport: _httpTransport,
      log: (message) => _log(message, level: Level.FINE),
      onRenewPreconditionFailed: (host) => _ensureEventSubscription(host),
    );
    _controlService = SonosControlService(
      transport: _httpTransport,
      discovery: _ssdpDiscovery,
      parser: _protocolParser,
      timeout: _httpTimeout,
      log: (message) => _log(message, level: Level.FINE),
    );
  }

  static const _httpTimeout = Duration(seconds: 10);
  final Logger _logger;
  final SonosHttpTransport _httpTransport;
  final SonosSsdpDiscovery _ssdpDiscovery;
  final SonosProtocolParser _protocolParser;
  late final SonosEventSubscription _eventSubscription;
  late final SonosControlService _controlService;
  final _controller = StreamController<NativeSonosMessage>.broadcast();
  final SonosProgressPoller _progressPoller = SonosProgressPoller();
  bool _trackProgressPollingEnabled = false;
  Duration? _trackProgressPollInterval;
  bool _running = false;
  Map<String, dynamic>? _coordinatorDevice;
  List<Map<String, dynamic>> _groupDevices = const [];

  // Event subscription
  HttpServer? _eventServer;
  Timer? _emitDebounce;
  int _notifyCount = 0;
  Future<_SonosDevice?>? _ongoingDiscovery;

  // Last known playback state from events
  String _transportState = 'UNKNOWN';
  Map<String, dynamic>? _currentTrack;
  Map<String, dynamic>? _playlist;
  Map<String, dynamic>? _nextTrack;
  bool get isSupported =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  Stream<NativeSonosMessage> get messages => _controller.stream;

  void _setCoordinator(_SonosDevice device) {
    _coordinatorDevice = {
      'id': device.uuid,
      'displayName': device.name,
      'ip': device.ip,
      'isCoordinator': device.isCoordinator,
    };
    _groupDevices = device.groupDevices ?? const [];
  }

  void _updateCurrentTrack(Map<String, dynamic> updates) {
    final merged = Map<String, dynamic>.from(_currentTrack ?? const {});
    updates.forEach((key, value) {
      if (value != null) {
        merged[key] = value;
      }
    });
    _currentTrack = merged;
  }

  Future<bool> probe({
    Duration timeout = const Duration(seconds: 15),
    bool forceRediscover = false,
    bool isGetLiveMedia = false,
    String method = 'lmp_zgs',
    int? maxHostsPerDiscovery,
  }) async {
    try {
      // When forcing rediscovery (e.g., after a health check failure), ignore
      // any cached coordinator so we actually validate reachability again.
      if (!forceRediscover) {
        final cached = _cachedCoordinator();
        if (cached != null) {
          return true;
        }
      } else {
        _coordinatorDevice = null;
        _groupDevices = const [];
        await _resetSubscriptionState(stopServer: true);
      }

      final device = await _discoverCoordinator(
          timeout: timeout,
          useCache: !forceRediscover,
          method: method,
          maxHostsPerDiscovery: maxHostsPerDiscovery);
      if (device == null) return false;
      _setCoordinator(device);
      return true;
    } catch (_) {
      _log('Probe failed (swallowed for probe semantics)', level: Level.FINE);
      return false;
    }
  }

  Future<void> start(
      {int? pollIntervalSec,
      int? trackProgressPollIntervalSec,
      bool enableTrackProgress = false,
      int? healthCheckSec,
      int? healthCheckRetry,
      int? healthCheckTimeoutSec,
      String method = 'lmp_zgs',
      int? maxHostsPerDiscovery}) async {
    if (_running) return;

    _progressPoller.stop();

    final effectiveTrackIntervalSec =
        trackProgressPollIntervalSec ?? pollIntervalSec;
    _trackProgressPollingEnabled = enableTrackProgress &&
        effectiveTrackIntervalSec != null &&
        effectiveTrackIntervalSec > 0;
    _trackProgressPollInterval = _trackProgressPollingEnabled
        ? Duration(seconds: effectiveTrackIntervalSec!)
        : null;

    // Any new discovery attempt should discard old subscriptions since prior
    // runs may have failed mid-subscribe. Start fresh so we always resubscribe
    // once a coordinator is found.
    await _resetSubscriptionState(stopServer: true);

    _log('Starting SSDP discovery for coordinator');
    final device = await _discoverCoordinator(
      method: method,
      maxHostsPerDiscovery: maxHostsPerDiscovery,
    );
    if (device == null) {
      throw Exception('No Sonos devices found on the local network');
    }

    _setCoordinator(device.copyWith(isCoordinator: true));
    final ip = _coordinatorDevice?['ip'] as String?;
    final name = _coordinatorDevice?['displayName'] as String?;
    _log('Using coordinator "$name@$ip"', level: Level.INFO);
    if (ip != null) {
      await _ensureEventSubscription(ip);
    }
    _running = true;

    _syncTrackProgressPolling();
  }

  Future<void> stop() async {
    _running = false;
    _progressPoller.stop();
    _emitDebounce?.cancel();
    _emitDebounce = null;
    await _unsubscribeFromEvents();
    await _stopEventServer();
    _log('Stopping native Sonos bridge', level: Level.FINE);
    _controller.add(NativeSonosMessage(
      serviceStatus: {
        'provider': 'sonos',
        'provider_display_name': 'Sonos',
        'status': 'stopped',
      },
    ));
  }

  Future<void> setTrackProgressPolling(
      {required bool enabled, int? intervalSec}) async {
    final seconds = intervalSec ?? 0;
    _trackProgressPollingEnabled = enabled && seconds > 0;
    _trackProgressPollInterval =
        _trackProgressPollingEnabled ? Duration(seconds: seconds) : null;
    _syncTrackProgressPolling();
  }

  Future<void> _emitPayload({bool isGetLiveMediaProgress = true}) async {
    final coord = _coordinatorDevice;
    final coordIp = coord?['ip'] as String?;
    final coordDisplayName = coord?['displayName'] as String?;
    final coordId = coord?['id'] as String?;
    final coordIsCoordinator = coord?['isCoordinator'] as bool? ?? false;

    if (coordIp == null || coordId == null) return;

    try {
      if (isGetLiveMediaProgress) {
        final liveMedia = await _controlService.getLiveMedia(
          host: coordIp,
          coordinatorName: coordDisplayName,
        );
        if (liveMedia != null) {
          final progressStr = liveMedia['current_progress_time'] as String?;
          final progressMs = _protocolParser.parseDurationMs(progressStr);
          final durationStr = liveMedia['duration'] as String?;
          final durationMs = _protocolParser.parseDurationMs(durationStr);
          final updates = <String, dynamic>{};
          if (progressMs != null) {
            updates['progress_ms'] = progressMs;
          }
          if (durationStr != null && durationStr.isNotEmpty) {
            updates['duration'] = durationStr;
          }
          if (durationMs != null) {
            updates['duration_ms'] = durationMs;
          }
          if (updates.isNotEmpty) {
            _updateCurrentTrack(updates);
          }
        }
      }

      final deviceName = coordDisplayName ?? 'Sonos';
      final groupDevices = _groupDevices
          .where((gd) => (gd['name'] as String?)?.isNotEmpty == true)
          .map((gd) => {
                'name': gd['name'],
                if (gd['location'] != null &&
                    (gd['location'] as String).isNotEmpty)
                  'location': gd['location'],
              })
          .toList();

      final payload = SonosPayloadBuilder.buildNowPlayingPayload(
        coordinatorIp: coordIp,
        coordinatorId: coordId,
        deviceName: deviceName,
        coordinator: coordIsCoordinator,
        transportState: _transportState,
        currentTrack: _currentTrack,
        playlist: _playlist,
        nextTrack: _nextTrack,
        groupDevices: groupDevices,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      // _log('Emitting payload: ${jsonEncode(payload)}', level: Level.FINE);
      _log('Emitting payload...', level: Level.FINE);
      _controller.add(NativeSonosMessage(payload: payload));
    } catch (e) {
      _log('Error emitting payload: $e', level: Level.FINE);
      _controller.add(NativeSonosMessage(error: e.toString()));
    }
  }

  void _syncTrackProgressPolling() {
    if (!_running ||
        !_trackProgressPollingEnabled ||
        _trackProgressPollInterval == null) {
      _progressPoller.stop();
      return;
    }

    _progressPoller.start(
      interval: _trackProgressPollInterval!,
      onTick: () async {
        if (!_running || !_trackProgressPollingEnabled) {
          return;
        }
        await _emitPayload();
      },
    );
  }

  Future<void> _resetSubscriptionState({bool stopServer = false}) async {
    // Best-effort unsubscribe; ignore failures because we're recovering from
    // a prior error state and just need a clean slate.
    try {
      await _eventSubscription.reset(timeout: _httpTimeout);
    } catch (_) {
      // Swallow errors on reset to avoid blocking rediscovery.
    }

    if (stopServer) {
      try {
        await _stopEventServer();
      } catch (_) {
        // Ignore cleanup errors during reset.
      }
    }
  }

  Future<void> _startEventServer() async {
    if (_eventServer != null) return;
    _eventServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _eventServer!.listen(_handleNotify, onError: (e) {
      _log('Event server error: $e', level: Level.WARNING);
    });
    _log('Event server listening on port ${_eventServer!.port}',
        level: Level.FINE);
  }

  Future<void> _stopEventServer() async {
    await _eventServer?.close(force: true);
    _eventServer = null;
  }

  Future<void> _ensureEventSubscription(String host) async {
    await _startEventServer();
    final callback = await _localCallbackUrl();
    if (callback == null) {
      _log('No reachable local IP for event callback; skipping subscription',
          level: Level.WARNING);
      return;
    }

    try {
      await _eventSubscription.subscribe(
        host: host,
        callbackUrl: callback,
        timeout: _httpTimeout,
      );
      _log('Subscribed to AVTransport events sid=${_eventSubscription.sid}',
          level: Level.FINE);
    } catch (e) {
      _log('Subscribe error: $e', level: Level.WARNING);
      _controller.add(NativeSonosMessage(
        error: 'subscribe_failed: $e',
      ));
    }
  }

  Future<void> _unsubscribeFromEvents() async {
    try {
      await _eventSubscription.unsubscribe(timeout: _httpTimeout);
    } catch (e) {
      _log('Unsubscribe error: $e', level: Level.WARNING);
      _controller.add(NativeSonosMessage(
        error: 'unsubscribe_failed: $e',
      ));
    }
  }

  Future<void> _handleNotify(HttpRequest request) async {
    try {
      final method = request.method.toUpperCase();
      if (method != 'NOTIFY') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      // Drop NOTIFY messages that arrive before we have a confirmed
      // subscription SID. This can happen when the speaker sends an event
      // immediately after discovery but before SUBSCRIBE completes, which
      // would otherwise be parsed with a null sid and leave us with incomplete
      // playback context.
      if (_eventSubscription.sid == null) {
        _log('Ignoring NOTIFY because subscription SID not yet established',
            level: Level.FINE);
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      final seqHeader = request.headers.value('seq');
      final seq = int.tryParse(seqHeader ?? '');

      final body = await utf8.decodeStream(request);
      _logNotify(request, body);
      _parseEventBody(body, seq: seq);
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    } catch (e) {
      _log('Notify handling error: $e', level: Level.WARNING);
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  void _parseEventBody(String body, {int? seq}) {
    try {
      final parsed = _protocolParser.parseEventBody(body);
      if (parsed == null || parsed.isEmpty) return;

      final transportState = parsed['transport_state'] as String?;
      if (transportState != null && transportState.isNotEmpty) {
        _transportState = transportState;
      }

      final currentTrackUpdates =
          parsed['current_track_updates'] as Map<String, dynamic>?;
      if (currentTrackUpdates != null && currentTrackUpdates.isNotEmpty) {
        _updateCurrentTrack(currentTrackUpdates);
      }

      final playlist = parsed['playlist'] as Map<String, dynamic>?;
      if (playlist != null) {
        _playlist = playlist;
      }

      final nextTrack = parsed['next_track'] as Map<String, dynamic>?;
      if (nextTrack != null) {
        _nextTrack = nextTrack;
      }

      _scheduleEmit(seq: seq);
    } catch (e) {
      _log('Event parse error: $e', level: Level.FINE);
    }
  }

  void _logNotify(HttpRequest request, String body) {
    final sid =
        request.headers.value('sid') ?? _eventSubscription.sid ?? '<none>';
    final seq = request.headers.value('seq') ?? '<none>';
    _notifyCount += 1;
    _log('NOTIFY #$_notifyCount sid=$sid seq=$seq bytes=${body.length}',
        level: Level.FINE);
  }

  void _scheduleEmit({int? seq}) {
    if (!_running) return;
    _emitDebounce?.cancel();
    // Debounce NOTIFY bursts; emit once per short window.
    _emitDebounce = Timer(const Duration(seconds: 1), () {
      _emitPayload();
    });
  }

  Future<String?> _localCallbackUrl() async {
    if (_eventServer == null) return null;
    final ip = await _findLocalIp();
    if (ip == null) return null;
    return 'http://$ip:${_eventServer!.port}/sonos-event';
  }

  Future<String?> _findLocalIp() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && addr.address.isNotEmpty) {
          return addr.address;
        }
      }
    }
    return null;
  }

  Future<_SonosDevice?> _discoverCoordinator({
    Duration timeout = const Duration(seconds: 15),
    bool useCache = true,
    String method = 'lmp_zgs',
    int? maxHostsPerDiscovery,
  }) async {
    // Reuse in-flight discovery to avoid parallel M-SEARCH bursts and
    // duplicate subscriptions when multiple probes overlap.
    if (_ongoingDiscovery != null) {
      return _ongoingDiscovery;
    }

    final completer = Completer<_SonosDevice?>();
    _ongoingDiscovery = completer.future.whenComplete(() {
      _ongoingDiscovery = null;
    });

    // Reuse cached coordinator to avoid repeated network discovery and avoid
    // triggering fallback thresholds when already healthy, unless explicitly
    // disabled (e.g., during recovery probes).
    if (useCache) {
      final cached = _cachedCoordinator();
      if (cached != null) {
        completer.complete(cached);
        return _ongoingDiscovery;
      }
    }

    _log('Sending SSDP M-SEARCH for Sonos ZonePlayers');
    final maxHosts = maxHostsPerDiscovery ?? 4; // 0 => unlimited

    final discoveredRaw = await _controlService.discoverCoordinator(
      timeout: timeout,
      method: method,
      maxHosts: maxHosts,
    );

    final discovered =
        discoveredRaw != null ? _deviceFromRaw(discoveredRaw) : null;
    if (discovered != null) {
      _log(
          'Coordinator discovered => ${discovered.name}@${discovered.ip} (uuid=${discovered.uuid})',
          level: Level.FINE);
    }

    completer.complete(discovered);

    return _ongoingDiscovery;
  }

  _SonosDevice? _cachedCoordinator() {
    final ip = _coordinatorDevice?['ip'] as String?;
    final name = _coordinatorDevice?['displayName'] as String?;
    final id = _coordinatorDevice?['id'] as String?;
    final isCoord = _coordinatorDevice?['isCoordinator'] as bool? ?? false;
    if (ip == null || name == null || id == null) return null;
    return _SonosDevice(
      ip: ip,
      name: name,
      uuid: id,
      isCoordinator: isCoord,
      groupDevices: _groupDevices,
    );
  }

  _SonosDevice _deviceFromRaw(Map<String, dynamic> raw) {
    final rawGroupDevices = raw['group_devices'];
    final groupDevices = rawGroupDevices is List
        ? rawGroupDevices
            .whereType<Map>()
            .map((item) => {
                  'name': item['name']?.toString() ?? '',
                  if (item['location'] != null)
                    'location': item['location']?.toString(),
                })
            .where((item) => (item['name'] as String).isNotEmpty)
            .toList()
        : const <Map<String, dynamic>>[];

    return _SonosDevice(
      ip: raw['ip']?.toString() ?? '',
      name: raw['name']?.toString() ?? 'Sonos',
      uuid: raw['uuid']?.toString(),
      isCoordinator: raw['is_coordinator'] == true,
      model: raw['model']?.toString(),
      roomName: raw['room_name']?.toString(),
      location: raw['location']?.toString(),
      idleState: raw['idle_state'] is int ? raw['idle_state'] as int : null,
      groupDevices: groupDevices,
    );
  }

  void _log(String message,
      {Level level = Level.INFO, Object? error, StackTrace? stackTrace}) {
    _logger.log(level, message, error, stackTrace);
  }
}

class _SonosDevice {
  _SonosDevice(
      {required this.ip,
      required this.name,
      this.uuid,
      this.isCoordinator = false,
      this.model,
      this.roomName,
      this.friendlyName,
      this.idleState,
      this.location,
      this.groupDevices});

  final String ip;
  final String name;
  final String? uuid;
  final int? idleState;
  final bool isCoordinator;
  final String? model;
  final String? roomName;
  final String? friendlyName;
  final String? location;
  final List<Map<String, dynamic>>? groupDevices;

  _SonosDevice copyWith(
      {String? ip,
      String? name,
      String? uuid,
      int? idleState,
      bool? isCoordinator,
      String? model,
      String? roomName,
      String? friendlyName,
      String? location,
      List<Map<String, dynamic>>? groupDevices}) {
    return _SonosDevice(
      ip: ip ?? this.ip,
      name: name ?? this.name,
      uuid: uuid ?? this.uuid,
      idleState: idleState ?? this.idleState,
      isCoordinator: isCoordinator ?? this.isCoordinator,
      model: model ?? this.model,
      roomName: roomName ?? this.roomName,
      friendlyName: friendlyName ?? this.friendlyName,
      location: location ?? this.location,
      groupDevices: groupDevices ?? this.groupDevices,
    );
  }
}
