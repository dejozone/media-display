import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:media_display/src/services/native_sonos_bridge_stub.dart';
import 'package:media_display/src/utils/logging.dart';
import 'package:xml/xml.dart' as xml;

/// macOS-native Sonos bridge that mirrors the backend coordinator selection.
class NativeSonosBridge {
  NativeSonosBridge() : _logger = appLogger('NativeSonosBridgeMacOS');

  static const _httpTimeout = Duration(seconds: 10);
  final Logger _logger;
  final _controller = StreamController<NativeSonosMessage>.broadcast();
  Timer? _pollTimer;
  bool _running = false;
  Map<String, dynamic>? _coordinatorDevice;
  List<_GroupDevice> _groupDevices = const [];

  // Event subscription
  HttpServer? _eventServer;
  String? _subscriptionSid;
  Timer? _subscriptionRenewTimer;
  Timer? _emitDebounce;
  int _notifyCount = 0;
  Future<_SonosDevice?>? _ongoingDiscovery;

  // Last known playback state from events
  String _transportState = 'UNKNOWN';
  Map<String, dynamic>? _currentTrack;
  Map<String, dynamic>? _playlist;
  Map<String, dynamic>? _nextTrack;
  bool get isSupported => Platform.isMacOS;

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
          timeout: timeout, useCache: !forceRediscover);
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
      int? healthCheckSec,
      int? healthCheckRetry,
      int? healthCheckTimeoutSec}) async {
    if (_running) return;

    // Any new discovery attempt should discard old subscriptions since prior
    // runs may have failed mid-subscribe. Start fresh so we always resubscribe
    // once a coordinator is found.
    await _resetSubscriptionState(stopServer: true);

    _log('Starting SSDP discovery for coordinator');
    final device = await _discoverCoordinator();
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

  Future<void> _emitPayload({bool isGetLiveMediaProgress = false}) async {
    final coord = _coordinatorDevice;
    final coordIp = coord?['ip'] as String?;
    final coordDisplayName = coord?['displayName'] as String?;
    final coordId = coord?['id'] as String?;
    final coordIsCoordinator = coord?['isCoordinator'] as bool? ?? false;

    if (coordIp == null || coordId == null) return;

    try {
      if (isGetLiveMediaProgress) {
        final liveMedia = await _getLiveMedia(host: coordIp);
        if (liveMedia != null) {
          final progressStr = liveMedia['current_progress_time'] as String?;
          final progressMs = _parseDurationMs(progressStr);
          if (progressMs != null) {
            _updateCurrentTrack({'progress_ms': progressMs});
          }
        }
      }

      final activeStates = {'PLAYING', 'TRANSITIONING', 'BUFFERING'};
      final isPlaying = activeStates.contains(_transportState);
      final playbackStatus = _transportState.toLowerCase();
      final deviceName = coordDisplayName ?? 'Sonos';
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
        'ip': coordIp,
        'uuid': coordId,
        'coordinator': coordIsCoordinator,
      };

      final artistsRaw = _currentTrack?['artists'];
      final artists = artistsRaw is List
          ? artistsRaw.whereType<String>().toList()
          : const <String>[];

      final trackBlock = <String, dynamic>{
        if (_currentTrack != null && _currentTrack!['id'] != null)
          'id': _currentTrack!['id'],
        'title': (_currentTrack?['title'] as String?) ?? '',
        'artist': artists.isNotEmpty ? artists.first : '',
        'album': _currentTrack?['album'],
        'artwork_url': _currentTrack?['artwork_url'],
        'duration_ms': _currentTrack?['duration_ms'],
        if (_playlist != null) 'playlist': _playlist,
      };

      final nextTrackBlock = _nextTrack ?? const {};
      final progressMs = _currentTrack?['progress_ms'] as int?;

      final payload = <String, dynamic>{
        // Server-aligned envelope
        'type': 'now_playing',
        'provider': 'sonos',
        'provider_display_name': 'Sonos',

        'data': {
          // Track: use server shape
          'track': trackBlock,

          // Playback: server shape + progress placeholder
          'playback': {
            'is_playing': isPlaying,
            'progress_ms': progressMs,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'status': playbackStatus,
            if (nextTrackBlock.isNotEmpty) 'next_track': nextTrackBlock,
          },

          // Device: server-required fields plus native identifiers
          'device': deviceBlock,
          'provider': 'sonos',
        },
      };
      _log('Emitting payload: ${jsonEncode(payload)}', level: Level.FINE);
      _controller.add(NativeSonosMessage(payload: payload));
    } catch (e) {
      _log('Error emitting payload: $e', level: Level.FINE);
      _controller.add(NativeSonosMessage(error: e.toString()));
    }
  }

  Future<HttpClientResponse> _makeApiCall({
    required Uri url,
    String method = 'GET',
    String? body,
    Map<String, String>? headers,
    Duration timeout = _httpTimeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    final verb = method.toUpperCase();
    final mergedHeaders = <String, String>{
      HttpHeaders.contentTypeHeader: 'text/xml; charset="utf-8"',
      if (headers != null) ...headers,
    };

    try {
      final req = await client.openUrl(verb, url).timeout(timeout);
      mergedHeaders.forEach((k, v) {
        req.headers.set(k, v);
      });

      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers
          ..chunkedTransferEncoding = false
          ..contentLength = bytes.length;
        req.add(bytes); // Sonos rejects chunked bodies; send raw bytes.
      }

      final resp = await req.close().timeout(timeout);
      return resp;
    } catch (e, st) {
      _log('HTTP $verb $url failed: $e',
          level: Level.FINE, error: e, stackTrace: st);
      client.close(force: true);
      rethrow;
    }
  }

  Future<void> _ensureEventSubscription(String host) async {
    await _startEventServer();
    await _subscribeToAvTransport(host);
  }

  Future<void> _resetSubscriptionState({bool stopServer = false}) async {
    _subscriptionRenewTimer?.cancel();
    _subscriptionRenewTimer = null;

    // Best-effort unsubscribe; ignore failures because we're recovering from
    // a prior error state and just need a clean slate.
    if (_subscriptionSid != null) {
      try {
        await _unsubscribeFromEvents();
      } catch (_) {
        // Swallow errors on reset to avoid blocking rediscovery.
      }
    }

    _subscriptionSid = null;

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
      final resp = await _makeApiCall(
        url: Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Event'),
        method: 'SUBSCRIBE',
        headers: {
          'CALLBACK': '<$callback>',
          'NT': 'upnp:event',
          'TIMEOUT': 'Second-600',
        },
      );
      final sid = resp.headers.value('sid');
      await resp.drain();
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
      _controller.add(NativeSonosMessage(
        error: 'subscribe_failed: $e',
      ));
    }
  }

  Future<void> _renewSubscription(String host) async {
    final sid = _subscriptionSid;
    if (sid == null) return;
    try {
      final resp = await _makeApiCall(
        url: Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Event'),
        method: 'SUBSCRIBE',
        headers: {
          'SID': sid,
          'TIMEOUT': 'Second-600',
        },
      );
      await resp.drain();
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
      _controller.add(NativeSonosMessage(
        error: 'renew_failed: $e',
      ));
    }
  }

  Future<void> _unsubscribeFromEvents() async {
    _subscriptionRenewTimer?.cancel();
    _subscriptionRenewTimer = null;
    final sid = _subscriptionSid;
    _subscriptionSid = null;
    final ip = _coordinatorDevice?['ip'] as String?;
    if (sid == null || ip == null) return;
    try {
      final resp = await _makeApiCall(
        url: Uri.parse('http://$ip:1400/MediaRenderer/AVTransport/Event'),
        method: 'UNSUBSCRIBE',
        headers: {'SID': sid},
      );
      await resp.drain();
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

        final playlistNode = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) =>
                e.name.local.toLowerCase() == 'enqueuedtransporturimetadata')
            .firstOrNull;
        final playlistMeta = playlistNode?.getAttribute('val');
        if (playlistMeta != null &&
            playlistMeta.isNotEmpty &&
            playlistMeta != 'NOT_IMPLEMENTED') {
          _playlist = _parsePlaylist(playlistMeta);
        }

        final nextMetaNode = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'nexttrackmetadata')
            .firstOrNull;
        final nextMetaVal = nextMetaNode?.getAttribute('val');
        if (nextMetaVal != null &&
            nextMetaVal.isNotEmpty &&
            nextMetaVal != 'NOT_IMPLEMENTED') {
          final nextMeta = _parseTrackMeta(nextMetaVal);
          _nextTrack = {
            if (nextMeta.title != null && nextMeta.title!.isNotEmpty)
              'title': nextMeta.title,
            if (nextMeta.creator != null && nextMeta.creator!.isNotEmpty)
              'artist': nextMeta.creator,
            if (nextMeta.album != null && nextMeta.album!.isNotEmpty)
              'album': nextMeta.album,
            if (nextMeta.artworkUrl != null && nextMeta.artworkUrl!.isNotEmpty)
              'artwork_url': nextMeta.artworkUrl,
          };
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
      final creator = _findText(item, const ['creator', 'artist']);
      final artists =
          creator != null && creator.isNotEmpty ? [creator] : const <String>[];
      _updateCurrentTrack({
        'id': trackId,
        'title': _findText(item, const ['title']),
        'album': _findText(item, const ['album']),
        'artists': artists,
        'artwork_url': _findText(item, const ['albumarturi', 'albumarturl']),
        'duration_ms': _findDurationMs(item),
      });
    } catch (e) {
      _log('DIDL parse error: $e', level: Level.FINE);
    }
  }

  Future<Map<String, dynamic>?> _getLiveMedia({String? host}) async {
    // Sonos does not include position in AVTransport events; fetch it via GetPositionInfo.
    final name = _coordinatorDevice?['displayName'] as String?;
    _log(
        'Attempting get live data about the media via GetPositionInfo from ${name ?? 'Sonos'} at $host',
        level: Level.FINE);
    if (host == null) return null;
    try {
      _log('Fetching content position via GetPositionInfo (Channel=Master)',
          level: Level.FINE);
      final envelope = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
    </u:GetPositionInfo>
  </s:Body>
</s:Envelope>''';

      final resp = await _makeApiCall(
        url: Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Control'),
        method: 'POST',
        body: envelope,
        headers: {
          'SOAPAction':
              '"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo"',
        },
      );
      if (resp.statusCode != 200) {
        final bodyText = await resp.transform(utf8.decoder).join();
        _log(
            'GetPositionInfo failed with status ${resp.statusCode} ${resp.reasonPhrase} $bodyText',
            level: Level.FINE);
        return null;
      }

      final body = await resp.transform(utf8.decoder).join();
      _log('GetPositionInfo response: $body', level: Level.FINE);

      final doc = xml.XmlDocument.parse(body);
      final relTime = doc.findAllElements('RelTime').firstOrNull?.innerText;
      final trackDuration =
          doc.findAllElements('TrackDuration').firstOrNull?.innerText;
      final trackNum = doc.findAllElements('Track').firstOrNull?.innerText;
      final trackUri = doc.findAllElements('TrackURI').firstOrNull?.innerText;
      final trackMetaRaw =
          doc.findAllElements('TrackMetaData').firstOrNull?.innerText;

      _log('GetPositionInfo relTime=$relTime trackDuration=$trackDuration',
          level: Level.FINE);

      final meta = _parseTrackMeta(trackMetaRaw);

      return {
        'id': meta.id,
        'parent_id': meta.parentId,
        'original_media_id': meta.originalMediaId,
        'num': trackNum,
        'uri': trackUri,
        'creator': meta.creator,
        'title': meta.title,
        'album_name': meta.album,
        'artwork_url': meta.artworkUrl,
        'duration': trackDuration,
        'current_progress_time': relTime,
      };
    } catch (e) {
      _log('GetPositionInfo error: $e', level: Level.FINE);
      return null;
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

  Map<String, dynamic>? _parsePlaylist(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'NOT_IMPLEMENTED') return null;
    try {
      final doc = xml.XmlDocument.parse(raw);
      final titleEl = doc.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'title')
          .firstOrNull;
      final title = titleEl?.innerText.trim();
      if (title == null || title.isEmpty) return null;
      return {'title': title};
    } catch (_) {
      return null;
    }
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

  _TrackMeta _parseTrackMeta(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'NOT_IMPLEMENTED') {
      return const _TrackMeta();
    }

    try {
      final doc = xml.XmlDocument.parse(raw);
      final item = doc.findAllElements('item').firstOrNull;
      if (item == null) return const _TrackMeta();

      final res = item.findAllElements('res').firstOrNull?.innerText.trim();
      final originalId = _extractSpotifyTrackId(res);

      return _TrackMeta(
        id: item.getAttribute('id'),
        parentId: item.getAttribute('parentID'),
        originalMediaId: originalId,
        creator: _findText(item, const ['creator', 'artist']),
        title: _findText(item, const ['title']),
        album: _findText(item, const ['album']),
        artworkUrl: _findText(item,
            const ['albumArtURI', 'albumArtURL', 'albumarturi', 'albumarturl']),
      );
    } catch (_) {
      return const _TrackMeta();
    }
  }

  String? _extractSpotifyTrackId(String? resText) {
    if (resText == null || resText.isEmpty) return null;
    final match = RegExp(r'((?:x-sonos-spotify:)?spotify:track:([^?&#\s]+))',
            caseSensitive: false)
        .firstMatch(resText);
    if (match == null) return null;
    final full = match.group(1);
    return full;
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

    var found = false;
    final attemptedHosts = <String>{};
    const maxHosts = 4; // Avoid hammering many responders; bail after a few
    StreamSubscription<RawSocketEvent>? sub;

    Future<void> _finalize(_SonosDevice? chosen) async {
      if (completer.isCompleted) return;
      found = true;
      socket.readEventsEnabled = false;
      await sub?.cancel();
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

  Future<_SonosDevice?> _fetchCoordinatorFromZoneGroup(String host) async {
    try {
      const envelope = '<?xml version="1.0" encoding="utf-8"?>\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
          '  <s:Body>\n'
          '    <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>\n'
          '  </s:Body>\n'
          '</s:Envelope>';

      final resp = await _makeApiCall(
        url: Uri.parse('http://$host:1400/ZoneGroupTopology/Control'),
        method: 'POST',
        body: envelope,
        headers: {
          HttpHeaders.contentTypeHeader: 'text/xml; charset="utf-8"',
          'SOAPACTION':
              '"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState"',
        },
      );
      if (resp.statusCode != 200) {
        _log('ZoneGroupTopology request failed (${resp.statusCode}) from $host',
            level: Level.FINE);
        await resp.drain();
        return null;
      }

      final body = await resp.transform(utf8.decoder).join();

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

class _TrackMeta {
  const _TrackMeta({
    this.id,
    this.parentId,
    this.originalMediaId,
    this.creator,
    this.title,
    this.album,
    this.artworkUrl,
  });

  final String? id;
  final String? parentId;
  final String? originalMediaId;
  final String? creator;
  final String? title;
  final String? album;
  final String? artworkUrl;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
