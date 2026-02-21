import 'dart:io';

import 'package:media_display/src/services/sonos_core/sonos_http_transport.dart';
import 'package:media_display/src/services/sonos_core/sonos_protocol_parser.dart';
import 'package:media_display/src/services/sonos_core/sonos_ssdp_discovery.dart';

class SonosControlService {
  const SonosControlService({
    required SonosHttpTransport transport,
    required SonosSsdpDiscovery discovery,
    required SonosProtocolParser parser,
    required Duration timeout,
    required void Function(String message) log,
  })  : _transport = transport,
        _discovery = discovery,
        _parser = parser,
        _timeout = timeout,
        _log = log;

  final SonosHttpTransport _transport;
  final SonosSsdpDiscovery _discovery;
  final SonosProtocolParser _parser;
  final Duration _timeout;
  final void Function(String message) _log;

  Future<Map<String, dynamic>?> discoverCoordinator({
    required Duration timeout,
    required String method,
    required int maxHosts,
  }) async {
    final methodLower = method.toLowerCase();
    return _discovery.discoverCoordinator<Map<String, dynamic>>(
      timeout: timeout,
      maxHosts: maxHosts,
      evaluateHost: (host) async {
        return methodLower == 'zgs_lmp'
            ? _getCoordinatorZgsLmp(host)
            : _getCoordinatorLmpZgs(host);
      },
    );
  }

  Future<String?> getZoneGroupTopology(String host) async {
    try {
      const envelope = '<?xml version="1.0" encoding="utf-8"?>\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
          '  <s:Body>\n'
          '    <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>\n'
          '  </s:Body>\n'
          '</s:Envelope>';

      final resp = await _transport.send(
        SonosHttpRequest(
          url: Uri.parse('http://$host:1400/ZoneGroupTopology/Control'),
          method: 'POST',
          body: envelope,
          headers: {
            HttpHeaders.contentTypeHeader: 'text/xml; charset="utf-8"',
            'SOAPACTION':
                '"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState"',
          },
          timeout: _timeout,
        ),
      );

      if (resp.statusCode != 200) {
        _log(
            'ZoneGroupTopology request failed (${resp.statusCode}) from $host');
        return null;
      }

      return resp.body;
    } catch (e) {
      _log('ZoneGroupTopology fetch error from $host: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLiveMedia({
    required String host,
    String? coordinatorName,
  }) async {
    _log(
        'Attempting get live data about the media via GetPositionInfo from ${coordinatorName ?? 'Sonos'} at $host');

    try {
      const envelope = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
    </u:GetPositionInfo>
  </s:Body>
</s:Envelope>''';

      final resp = await _transport.send(
        SonosHttpRequest(
          url: Uri.parse('http://$host:1400/MediaRenderer/AVTransport/Control'),
          method: 'POST',
          body: envelope,
          headers: {
            HttpHeaders.contentTypeHeader: 'text/xml; charset="utf-8"',
            'SOAPAction':
                '"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo"',
          },
          timeout: _timeout,
        ),
      );

      if (resp.statusCode != 200) {
        _log(
            'GetPositionInfo (from host=$host) failed with status ${resp.statusCode} ${resp.reasonPhrase} ${resp.body}');
        return null;
      }

      final body = resp.body;
      final relTime = _extractTag(body, 'RelTime');
      final trackDuration = _extractTag(body, 'TrackDuration');
      final trackNum = _extractTag(body, 'Track');
      final trackUri = _extractTag(body, 'TrackURI');
      final trackMetaRaw = _extractTag(body, 'TrackMetaData');

      _log(
          'GetPositionInfo (from host=$host) relTime=$relTime trackDuration=$trackDuration');

      final meta = _parser.parseTrackMeta(trackMetaRaw);

      return {
        'id': meta['id'],
        'parent_id': meta['parent_id'],
        'original_media_id': meta['original_media_id'],
        'num': trackNum,
        'uri': trackUri,
        'creator': meta['creator'],
        'title': meta['title'],
        'album_name': meta['album'],
        'artwork_url': meta['artwork_url'],
        'duration': trackDuration,
        'current_progress_time': relTime,
      };
    } catch (e) {
      _log('GetPositionInfo (from host=$host) error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getCoordinatorZgsLmp(String host) async {
    try {
      _log('Fetching coordinator info via ZGS->LMP from $host');
      final body = await getZoneGroupTopology(host);
      if (body == null) return null;

      final coordinator = _parser.parseCoordinatorFromZoneGroupState(body);
      if (coordinator == null) return null;

      final liveMedia = await getLiveMedia(
          host: host, coordinatorName: coordinator['name'] as String?);
      final uri = (liveMedia?['uri'] as String?)?.trim();
      final title = (liveMedia?['title'] as String?)?.trim();

      if ((uri != null && uri.isNotEmpty && uri != 'NOT_IMPLEMENTED') ||
          (title != null && title.isNotEmpty)) {
        return coordinator;
      }

      _log('Live media missing uri/title on $host; skipping as coordinator');
      return null;
    } catch (e) {
      _log('Coordinator fetch error from $host: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getCoordinatorLmpZgs(String host) async {
    try {
      _log('Fetching coordinator info via LMP->ZGS from $host');
      final liveMedia = await getLiveMedia(host: host);
      final candidateFields = <String?>[
        liveMedia?['uri'] as String?,
        liveMedia?['original_media_id'] as String?,
        liveMedia?['id'] as String?,
      ];

      String? coordinatorUuid;
      for (final field in candidateFields) {
        coordinatorUuid = _extractUuidFromUri(field);
        if (coordinatorUuid != null && coordinatorUuid.isNotEmpty) {
          break;
        }
      }

      if (coordinatorUuid == null || coordinatorUuid.isEmpty) {
        _log('Coordinator UUID not found in live media from $host');
        return null;
      }

      final body = await getZoneGroupTopology(host);
      if (body == null) return null;

      return _parser.parseDeviceFromZoneGroupStateByTargetUuid(
        body: body,
        targetUuid: coordinatorUuid.toUpperCase(),
      );
    } catch (e) {
      _log('Coordinator LMP->ZGS fetch error from $host: $e');
      return null;
    }
  }

  String? _extractUuidFromUri(String? text) {
    if (text == null || text.isEmpty) return null;

    final preComma = text.split(',').first;
    final parts = preComma.split(':');
    if (parts.length < 2) return null;
    return parts[1].trim();
  }

  String? _extractTag(String xmlBody, String tagName) {
    final open = '<$tagName>';
    final close = '</$tagName>';
    final start = xmlBody.indexOf(open);
    if (start < 0) return null;
    final end = xmlBody.indexOf(close, start + open.length);
    if (end < 0) return null;
    return xmlBody.substring(start + open.length, end);
  }
}
