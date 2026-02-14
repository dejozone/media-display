import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:media_display/src/services/native_sonos_bridge_stub.dart';
import 'package:media_display/src/utils/logging.dart';
import 'package:xml/xml.dart' as xml;

/// macOS-native Sonos bridge that mirrors the backend coordinator selection.
class NativeSonosBridge {
  NativeSonosBridge({bool enableProgress = true})
      : _enableProgress = enableProgress,
        _logger = appLogger('NativeSonosBridgeMacOS');

  final Logger _logger;
  final _controller = StreamController<NativeSonosMessage>.broadcast();
  Timer? _pollTimer;
  bool _running = false;
  String? _deviceIp;
  String? _deviceName;
  bool _deviceIsCoordinator = false;
  String? _coordinatorUuid;

  // Event subscription
  HttpServer? _eventServer;
  String? _subscriptionSid;
  Timer? _subscriptionRenewTimer;
  Timer? _emitDebounce;
  int _notifyCount = 0;

  // Last known playback state from events
  String _transportState = 'UNKNOWN';
  String? _currentTitle;
  String? _currentAlbum;
  List<String> _currentArtists = const [];
  String? _currentAlbumArt;
  String? _currentTrackId;
  int? _currentDurationMs;
  int? _currentProgressMs;
  List<_GroupDevice> _groupDevices = const [];
  bool _enableProgress;
  DateTime? _lastPositionFetch;
  String? _lastPositionTrackId;
  String? _lastPositionState;
  DateTime? _positionBackoffUntil;

  static const _httpTimeout = Duration(seconds: 10);

  bool get isSupported => Platform.isMacOS;

  Stream<NativeSonosMessage> get messages => _controller.stream;

  Future<bool> probe({Duration timeout = const Duration(seconds: 15)}) async {
    try {
      // If we already have a coordinator, treat probe as healthy
      final cached = _cachedCoordinator();
      if (cached != null) {
        return true;
      }

      final device = await _discoverCoordinator(timeout: timeout);
      if (device == null) return false;
      _deviceIp = device.ip;
      _deviceName = device.name;
      _deviceIsCoordinator = device.isCoordinator;
      _coordinatorUuid = device.uuid;
      _groupDevices = device.groupDevices ?? const [];
      return true;
    } catch (_) {
      _log('Probe failed (swallowed for probe semantics)', level: Level.FINE);
      return false;
    }
  }

  Future<void> start({int? pollIntervalSec}) async {
    if (_running) return;

    _log('Starting SSDP discovery for coordinator');
    final device = await _discoverCoordinator();
    if (device == null) {
      throw Exception('No Sonos devices found on the local network');
    }

    _deviceIp = device.ip;
    _deviceName = device.name;
    _deviceIsCoordinator = true; // We only emit a single chosen coordinator
    _coordinatorUuid = device.uuid;
    _groupDevices = device.groupDevices ?? const [];
    _log('Using coordinator $_deviceName@$_deviceIp', level: Level.INFO);
    await _ensureEventSubscription(_deviceIp!);
    _running = true;

    // Emit once on startup; subsequent updates come from event callbacks.
    await _emitPayload();
  }

  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
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

  Future<void> _emitPayload() async {
    if (!_running || _deviceIp == null) return;

    try {
      await _maybeRefreshPosition();

      final activeStates = {'PLAYING', 'TRANSITIONING', 'BUFFERING'};
      final isPlaying = activeStates.contains(_transportState);
      final playbackStatus = _transportState.toLowerCase();
      final deviceName = _deviceName ?? 'Sonos';
      final groupDevices = _groupDevices
          .where((gd) => gd.name.isNotEmpty)
          .map((gd) => {
                'name': gd.name,
                if (gd.location != null && gd.location!.isNotEmpty)
                  'location': gd.location,
              })
          .toList();

      // Build shared blocks once so we can place them both top-level and under data
      final deviceBlock = {
        'name': deviceName,
        'type': 'speaker',
        'group_devices': groupDevices,
        'ip': _deviceIp,
        'uuid': _coordinatorUuid,
        'coordinator': _deviceIsCoordinator,
      };

      final payload = <String, dynamic>{
        // Server-aligned envelope
        'type': 'now_playing',
        'provider': 'sonos',
        'provider_display_name': 'Sonos',

        'data': {
          // Track: use server shape
          'track': {
            if (_currentTrackId != null) 'id': _currentTrackId,
            'title': _currentTitle ?? '',
            'artist': _currentArtists.isNotEmpty ? _currentArtists.first : '',
            'album': _currentAlbum,
            'artwork_url': _currentAlbumArt,
            'duration_ms': _currentDurationMs,
          },

          // Playback: server shape + progress placeholder
          'playback': {
            'is_playing': isPlaying,
            'progress_ms': _currentProgressMs,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'status': playbackStatus,
          },

          // Device: server-required fields plus native identifiers
          'device': deviceBlock,
          'provider': 'sonos',
        },
      };
      _log('Emitting native payload: ${jsonEncode(payload)}',
          level: Level.FINE);
      _controller.add(NativeSonosMessage(payload: payload));
    } catch (e) {
      _log('Error emitting payload: $e', level: Level.FINE);
      _controller.add(NativeSonosMessage(error: e.toString()));
    }
  }

  Future<void> _ensureEventSubscription(String host) async {
    await _startEventServer();
    await _subscribeToAvTransport(host);
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

  Future<void> _subscribeToAvTransport(String host) async {
    if (_subscriptionSid != null) {
      _log('Already subscribed to AVTransport sid=$_subscriptionSid, skipping',
          level: Level.FINE);
      return;
    }

    final callback = await _localCallbackUrl();
    if (callback == null) {
      _log('No reachable local IP for event callback; skipping subscription',
          level: Level.WARNING);
      return;
    }

    try {
      final client = HttpClient();
      final req = await client.openUrl('SUBSCRIBE',
          Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Event'));
      req.headers.set('CALLBACK', '<$callback>');
      req.headers.set('NT', 'upnp:event');
      req.headers.set('TIMEOUT', 'Second-600');

      final resp = await req.close().timeout(_httpTimeout);
      final sid = resp.headers.value('sid');
      client.close(force: true);
      if (sid == null || sid.isEmpty) {
        _log('Subscription failed: missing SID', level: Level.WARNING);
        return;
      }
      _subscriptionSid = sid;
      _log('Subscribed to AVTransport events sid=$sid', level: Level.FINE);

      _subscriptionRenewTimer?.cancel();
      _subscriptionRenewTimer = Timer(const Duration(seconds: 540), () {
        _renewSubscription(host);
      });
    } catch (e) {
      _log('Subscribe error: $e', level: Level.WARNING);
    }
  }

  Future<void> _renewSubscription(String host) async {
    final sid = _subscriptionSid;
    if (sid == null) return;
    try {
      final client = HttpClient();
      final req = await client.openUrl('SUBSCRIBE',
          Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Event'));
      req.headers.set('SID', sid);
      req.headers.set('TIMEOUT', 'Second-600');
      final resp = await req.close().timeout(_httpTimeout);
      client.close(force: true);
      if (resp.statusCode == 412) {
        // Precondition failed, retry full subscribe
        _subscriptionSid = null;
        await _subscribeToAvTransport(host);
        return;
      }
      _subscriptionRenewTimer?.cancel();
      _subscriptionRenewTimer = Timer(const Duration(seconds: 540), () {
        _renewSubscription(host);
      });
      _log('Renewed subscription sid=$sid', level: Level.FINE);
    } catch (e) {
      _log('Renew error: $e', level: Level.WARNING);
    }
  }

  Future<void> _unsubscribeFromEvents() async {
    _subscriptionRenewTimer?.cancel();
    _subscriptionRenewTimer = null;
    final sid = _subscriptionSid;
    _subscriptionSid = null;
    if (sid == null || _deviceIp == null) return;
    try {
      final client = HttpClient();
      final req = await client.openUrl(
          'UNSUBSCRIBE',
          Uri.parse(
              'http://${_deviceIp}:1400/MediaRenderer/AVTransport/Event'));
      req.headers.set('SID', sid);
      await req.close().timeout(_httpTimeout);
      client.close(force: true);
    } catch (_) {
      // ignore
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
      final doc = xml.XmlDocument.parse(body);
      // _log('sonos event: ${doc.toXmlString(pretty: true)}', level: Level.FINE);
      final lastChange = doc.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'lastchange')
          .firstOrNull;
      if (lastChange == null) return;
      final lastChangeRaw = lastChange.innerText.trim();
      if (lastChangeRaw.isEmpty) return;

      final lcDoc = xml.XmlDocument.parse(lastChangeRaw);
      final event = lcDoc.descendants
              .whereType<xml.XmlElement>()
              .where((e) => e.name.local.toLowerCase() == 'event')
              .firstOrNull ??
          lcDoc.rootElement;
      for (final inst in event.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'instanceid')) {
        final state = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'transportstate')
            .firstOrNull;
        final val = state?.getAttribute('val');
        if (val != null && val.isNotEmpty) {
          _transportState = val;
        }

        final metaNode = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'currenttrackmetadata')
            .firstOrNull;
        final meta = metaNode?.getAttribute('val');
        if (meta != null && meta.isNotEmpty && meta != 'NOT_IMPLEMENTED') {
          _parseDidl(meta);
        }
      }

      _scheduleEmit(seq: seq);
    } catch (e) {
      _log('Event parse error: $e', level: Level.FINE);
    }
  }

  void _logNotify(HttpRequest request, String body) {
    final sid = request.headers.value('sid') ?? _subscriptionSid ?? '<none>';
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

  void _parseDidl(String didl) {
    try {
      final doc = xml.XmlDocument.parse(didl);
      final item = doc.findAllElements('item').firstOrNull;
      // _log('DIDL item=${item?.toXmlString(pretty: true)}', level: Level.FINE);
      if (item == null) return;
      final trackId = _findTrackId(item);
      if (trackId != null && trackId.isNotEmpty) {
        _currentTrackId = trackId;
      }
      _currentTitle = _findText(item, const ['title']);
      _currentAlbum = _findText(item, const ['album']);
      final creator = _findText(item, const ['creator', 'artist']);
      _currentArtists =
          creator != null && creator.isNotEmpty ? [creator] : const [];
      _currentAlbumArt = _findText(item, const ['albumarturi', 'albumarturl']);
      _currentDurationMs = _findDurationMs(item) ?? _currentDurationMs;
    } catch (e) {
      _log('DIDL parse error: $e', level: Level.FINE);
    }
  }

  Future<void> _maybeRefreshPosition() async {
    if (!_enableProgress) {
      _currentProgressMs = null;
      return;
    }

    if (_positionBackoffUntil != null &&
        DateTime.now().isBefore(_positionBackoffUntil!)) {
      return;
    }

    const activeStates = {'PLAYING', 'BUFFERING'};
    if (!activeStates.contains(_transportState)) return;

    final now = DateTime.now();
    final trackChanged = _lastPositionTrackId != _currentTrackId;
    final stateChanged = _lastPositionState != _transportState;
    final tooRecent = _lastPositionFetch != null &&
        now.difference(_lastPositionFetch!) < const Duration(seconds: 1);

    if (!trackChanged && !stateChanged && tooRecent) return;

    await _refreshPosition(host: _deviceIp);
    _lastPositionFetch = now;
    _lastPositionTrackId = _currentTrackId;
    _lastPositionState = _transportState;
  }

  Future<void> _refreshPosition({String? host}) async {
    // Sonos does not include position in AVTransport events; fetch it via GetPositionInfo.
    host ??= _deviceIp;
    _log(
        'Attempting to refresh position via GetPositionInfo for $_deviceName at $host',
        level: Level.FINE);
    if (host == null) return;
    try {
      _log('Fetching position via GetPositionInfo', level: Level.FINE);
      final client = HttpClient();
      final req = await client.postUrl(
          Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Control'));
      req.headers
          .set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION',
          '"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo"');
      const envelope = '<?xml version="1.0" encoding="utf-8"?>\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
          '  <s:Body>\n'
          '    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\n'
          '      <InstanceID>0</InstanceID>\n'
          '    </u:GetPositionInfo>\n'
          '  </s:Body>\n'
          '</s:Envelope>';
      req.write(envelope);

      final resp = await req.close();
      if (resp.statusCode != 200) {
        final bodyText = await resp.transform(utf8.decoder).join();
        _log(
            'GetPositionInfo failed with status ${resp.statusCode} ${resp.reasonPhrase} $bodyText',
            level: Level.FINE);
        client.close(force: true);
        return;
      }
      final body = await resp.transform(utf8.decoder).join();
      _log('GetPositionInfo response: $body', level: Level.FINE);
      client.close(force: true);

      final doc = xml.XmlDocument.parse(body);
      final relTime = doc.findAllElements('RelTime').firstOrNull?.innerText;
      final trackDuration =
          doc.findAllElements('TrackDuration').firstOrNull?.innerText;

      _log('GetPositionInfo relTime=$relTime trackDuration=$trackDuration',
          level: Level.FINE);

      final relMs = _parseDurationMs(relTime);
      if (relMs != null) {
        _currentProgressMs = relMs;
      }
      final durMs = _parseDurationMs(trackDuration);
      if (durMs != null && _currentDurationMs == null) {
        _currentDurationMs = durMs;
      }

      // Success resets error streak/backoff
      _positionBackoffUntil = null;
    } catch (e) {
      _log('GetPositionInfo error: $e', level: Level.FINE);
    }
  }

  String? _findTrackId(xml.XmlElement root) {
    try {
      for (final res in root.findAllElements('res')) {
        final text = res.innerText.trim();
        if (text.isEmpty) continue;
        final match = RegExp(r'track:([^?&#/]+)').firstMatch(text);
        if (match != null) {
          return match.group(1);
        }
      }
    } catch (_) {}

    final attrId = root.getAttribute('id');
    if (attrId != null && attrId.isNotEmpty) {
      return attrId;
    }
    return null;
  }

  int? _findDurationMs(xml.XmlElement root) {
    try {
      for (final res in root.findAllElements('res')) {
        final dur = res.getAttribute('duration');
        final parsed = _parseDurationMs(dur);
        if (parsed != null) return parsed;
      }
    } catch (_) {}
    return null;
  }

  int? _parseDurationMs(String? duration) {
    if (duration == null || duration.isEmpty) return null;
    if (duration.toUpperCase() == 'NOT_IMPLEMENTED') return null;
    // Formats like HH:MM:SS or HH:MM:SS.mmm
    final parts = duration.split(':');
    if (parts.length < 2) return null;
    int hours = 0, minutes = 0;
    double seconds = 0;
    try {
      if (parts.length == 3) {
        hours = int.parse(parts[0]);
        minutes = int.parse(parts[1]);
        seconds = double.parse(parts[2]);
      } else if (parts.length == 2) {
        minutes = int.parse(parts[0]);
        seconds = double.parse(parts[1]);
      }
      final totalMs = ((hours * 3600) + (minutes * 60) + seconds) * 1000;
      return totalMs.round();
    } catch (_) {
      return null;
    }
  }

  String? _findText(xml.XmlElement root, List<String> localNames) {
    final lowered = localNames.map((e) => e.toLowerCase()).toSet();
    for (final el in root.descendants.whereType<xml.XmlElement>()) {
      if (lowered.contains(el.name.local.toLowerCase())) {
        return el.innerText;
      }
    }
    return null;
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

  Future<_SonosDevice?> _discoverCoordinator(
      {Duration timeout = const Duration(seconds: 15)}) async {
    // Reuse cached coordinator to avoid repeated network discovery and avoid
    // triggering fallback thresholds when already healthy.
    final cached = _cachedCoordinator();
    if (cached != null) {
      return cached;
    }

    _log('Sending SSDP M-SEARCH for Sonos ZonePlayers', level: Level.FINE);
    const mcast = '239.255.255.250';
    const port = 1900;
    const searchTarget = 'urn:schemas-upnp-org:device:ZonePlayer:1';
    final message = [
      'M-SEARCH * HTTP/1.1',
      'HOST: $mcast:$port',
      'MAN: "ssdp:discover"',
      'MX: 1',
      'ST: $searchTarget',
      '',
      '',
    ].join('\r\n');

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.readEventsEnabled = true;

    socket.send(utf8.encode(message), InternetAddress(mcast), port);
    Timer(const Duration(seconds: 1), () {
      socket.send(utf8.encode(message), InternetAddress(mcast), port);
    });

    final completer = Completer<_SonosDevice?>();
    var found = false;
    final attemptedHosts = <String>{};
    const maxHosts = 4; // Avoid hammering many responders; bail after a few
    StreamSubscription<RawSocketEvent>? sub;

    Future<void> _finalize(_SonosDevice? chosen) async {
      if (completer.isCompleted) return;
      found = true;
      socket.readEventsEnabled = false;
      await sub?.cancel();
      _deviceIsCoordinator = chosen?.isCoordinator ?? false;
      completer.complete(chosen);
      socket.close();
    }

    Future.delayed(timeout, () async {
      if (completer.isCompleted) return;
      await _finalize(null);
    });

    final pendingHosts = <String>[];
    var processing = false;
    Future<void> _processNext() async {
      if (processing || found || pendingHosts.isEmpty) return;
      processing = true;
      final host = pendingHosts.removeAt(0);
      final coord = await _fetchCoordinatorFromZoneGroup(host);
      if (found) {
        processing = false;
        return;
      }
      if (coord != null) {
        _log(
            'Coordinator discovered via $host => ${coord.name}@${coord.ip} (uuid=${coord.uuid})',
            level: Level.FINE);
        await _finalize(coord);
        processing = false;
        return;
      }
      processing = false;
      // Continue with next host if any
      await _processNext();
    }

    sub = socket.listen((event) async {
      if (completer.isCompleted || found) return;
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();
        if (dg == null) return;
        final data = utf8.decode(dg.data, allowMalformed: true);
        final location = _parseHeader(data, 'LOCATION');
        if (location == null) return;
        final uri = Uri.tryParse(location);
        final host = uri?.host;
        if (host == null || host.isEmpty) return;
        if (attemptedHosts.contains(host)) return;
        if (attemptedHosts.length >= maxHosts) return;
        attemptedHosts.add(host);
        pendingHosts.add(host);
        await _processNext();
      }
    }, onError: (_) {
      _finalize(null);
    });

    return completer.future;
  }

  _SonosDevice? _cachedCoordinator() {
    if (_deviceIp == null || _deviceName == null || _coordinatorUuid == null) {
      return null;
    }
    return _SonosDevice(
      ip: _deviceIp!,
      name: _deviceName!,
      uuid: _coordinatorUuid,
      isCoordinator: true,
      groupDevices: _groupDevices,
    );
  }

  Future<_SonosDevice?> _fetchCoordinatorFromZoneGroup(String host) async {
    try {
      final client = HttpClient();
      final req = await client
          .postUrl(Uri.parse('http://$host:1400/ZoneGroupTopology/Control'));
      req.headers
          .set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION',
          '"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState"');
      const envelope = '<?xml version="1.0" encoding="utf-8"?>\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
          '  <s:Body>\n'
          '    <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>\n'
          '  </s:Body>\n'
          '</s:Envelope>';
      req.write(envelope);

      final resp = await req.close();
      if (resp.statusCode != 200) {
        _log('ZoneGroupTopology request failed (${resp.statusCode}) from $host',
            level: Level.FINE);
        client.close(force: true);
        return null;
      }

      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);

      // _logXml('ZoneGroupTopology raw from $host', body);
      final coordinator = _parseCoordinatorFromZoneGroupState(body);
      return coordinator;
    } catch (e) {
      _log('ZoneGroupTopology fetch error from $host: $e', level: Level.FINE);
      return null;
    }
  }

  _SonosDevice? _parseCoordinatorFromZoneGroupState(String body) {
    try {
      final outer = xml.XmlDocument.parse(body);
      final zgStateNode = outer.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'zonegroupstate')
          .firstOrNull;
      if (zgStateNode == null) return null;
      final innerRaw = zgStateNode.innerText.trim();
      if (innerRaw.isEmpty) return null;

      final zgDoc = xml.XmlDocument.parse(innerRaw);
      for (final group in zgDoc.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'zonegroup')) {
        final coordinatorId = group.getAttribute('Coordinator');
        if (coordinatorId == null || coordinatorId.isEmpty) continue;

        // Skip groups that are purely Boost/bridge
        final members = group.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'zonegroupmember')
            .toList();
        if (members.isEmpty) continue;
        final allBoost = members.every(
            (m) => (m.getAttribute('ZoneName') ?? '').toLowerCase() == 'boost');
        if (allBoost) continue;

        final groupDevices = <_GroupDevice>[];
        for (final member in members) {
          final name = member.getAttribute('ZoneName');
          final location = member.getAttribute('Location');
          if (name != null && name.isNotEmpty) {
            groupDevices.add(_GroupDevice(name: name, location: location));
          }
        }

        for (final member in members) {
          final uuid = member.getAttribute('UUID') ?? '';
          if (uuid.toUpperCase() != coordinatorId.toUpperCase()) continue;

          // IdleState: 0 = active, 1 = idle. Skip idle coordinators.
          final idleState = member.getAttribute('IdleState');
          if (idleState != null && idleState != '0') {
            continue;
          }

          final location = member.getAttribute('Location');
          final zoneName = member.getAttribute('ZoneName') ?? 'Sonos';
          final model = member.getAttribute('ModelNumber');
          final ip = _hostFromLocation(location);
          if (ip == null || ip.isEmpty) continue;
          return _SonosDevice(
            ip: ip,
            name: zoneName,
            uuid: uuid,
            isCoordinator: true,
            model: model,
            roomName: zoneName,
            groupDevices: groupDevices,
          );
        }
      }
    } catch (e) {
      _log('ZoneGroupState parse error: $e', level: Level.FINE);
    }
    return null;
  }

  String? _hostFromLocation(String? location) {
    if (location == null || location.isEmpty) return null;
    final uri = Uri.tryParse(location);
    return uri?.host;
  }

  String? _parseHeader(String data, String header) {
    final lines = const LineSplitter().convert(data);
    final prefix = '$header:';
    for (final line in lines) {
      if (line.toUpperCase().startsWith(prefix.toUpperCase())) {
        return line.substring(prefix.length).trim();
      }
    }
    return null;
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
      this.groupDevices});

  final String ip;
  final String name;
  final String? uuid;
  final bool isCoordinator;
  final String? model;
  final String? roomName;
  final String? friendlyName;
  final List<_GroupDevice>? groupDevices;

  _SonosDevice copyWith(
      {String? ip,
      String? name,
      String? uuid,
      bool? isCoordinator,
      String? model,
      String? roomName,
      String? friendlyName,
      List<_GroupDevice>? groupDevices}) {
    return _SonosDevice(
      ip: ip ?? this.ip,
      name: name ?? this.name,
      uuid: uuid ?? this.uuid,
      isCoordinator: isCoordinator ?? this.isCoordinator,
      model: model ?? this.model,
      roomName: roomName ?? this.roomName,
      friendlyName: friendlyName ?? this.friendlyName,
      groupDevices: groupDevices ?? this.groupDevices,
    );
  }
}

class _GroupDevice {
  const _GroupDevice({required this.name, this.location});
  final String name;
  final String? location;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
