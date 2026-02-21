import 'package:xml/xml.dart' as xml;

class SonosProtocolParser {
  const SonosProtocolParser();

  Map<String, dynamic>? parseEventBody(String body) {
    try {
      final doc = xml.XmlDocument.parse(body);
      final lastChange = doc.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'lastchange')
          .firstOrNull;
      if (lastChange == null) return null;

      final lastChangeRaw = lastChange.innerText.trim();
      if (lastChangeRaw.isEmpty) return null;

      final lcDoc = xml.XmlDocument.parse(lastChangeRaw);
      final event = lcDoc.descendants
              .whereType<xml.XmlElement>()
              .where((e) => e.name.local.toLowerCase() == 'event')
              .firstOrNull ??
          lcDoc.rootElement;

      String? transportState;
      Map<String, dynamic>? currentTrackUpdates;
      Map<String, dynamic>? playlist;
      Map<String, dynamic>? nextTrack;

      for (final inst in event.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'instanceid')) {
        final state = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'transportstate')
            .firstOrNull;
        final val = state?.getAttribute('val');
        if (val != null && val.isNotEmpty) {
          transportState = val;
        }

        final metaNode = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'currenttrackmetadata')
            .firstOrNull;
        final meta = metaNode?.getAttribute('val');
        if (meta != null && meta.isNotEmpty && meta != 'NOT_IMPLEMENTED') {
          final didlUpdates = parseDidlTrackUpdates(meta);
          if (didlUpdates != null && didlUpdates.isNotEmpty) {
            currentTrackUpdates = didlUpdates;
          }
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
          playlist = parsePlaylist(playlistMeta) ?? playlist;
        }

        final nextMetaNode = inst.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'nexttrackmetadata')
            .firstOrNull;
        final nextMetaVal = nextMetaNode?.getAttribute('val');
        if (nextMetaVal != null &&
            nextMetaVal.isNotEmpty &&
            nextMetaVal != 'NOT_IMPLEMENTED') {
          final nextMeta = parseTrackMeta(nextMetaVal);
          nextTrack = {
            if ((nextMeta['title'] as String?)?.isNotEmpty == true)
              'title': nextMeta['title'],
            if ((nextMeta['creator'] as String?)?.isNotEmpty == true)
              'artist': nextMeta['creator'],
            if ((nextMeta['album'] as String?)?.isNotEmpty == true)
              'album': nextMeta['album'],
            if ((nextMeta['artwork_url'] as String?)?.isNotEmpty == true)
              'artwork_url': nextMeta['artwork_url'],
          };
        }
      }

      return {
        if (transportState != null) 'transport_state': transportState,
        if (currentTrackUpdates != null)
          'current_track_updates': currentTrackUpdates,
        if (playlist != null) 'playlist': playlist,
        if (nextTrack != null) 'next_track': nextTrack,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? parseDidlTrackUpdates(String didl) {
    try {
      final doc = xml.XmlDocument.parse(didl);
      final item = doc.findAllElements('item').firstOrNull;
      if (item == null) return null;

      final trackId = _findTrackId(item);
      final creator = _findText(item, const ['creator', 'artist']);
      final artists =
          creator != null && creator.isNotEmpty ? [creator] : const <String>[];

      return {
        'id': trackId,
        'title': _findText(item, const ['title']),
        'album': _findText(item, const ['album']),
        'artists': artists,
        'artwork_url': _findText(item, const ['albumarturi', 'albumarturl']),
        'duration_ms': _findDurationMs(item),
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? parsePlaylist(String? raw) {
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

  Map<String, dynamic> parseTrackMeta(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'NOT_IMPLEMENTED') {
      return const {};
    }

    try {
      final doc = xml.XmlDocument.parse(raw);
      final item = doc.findAllElements('item').firstOrNull;
      if (item == null) return const {};

      final res = item.findAllElements('res').firstOrNull?.innerText.trim();
      final originalId = _extractSpotifyTrackId(res);

      return {
        'id': item.getAttribute('id'),
        'parent_id': item.getAttribute('parentID'),
        'original_media_id': originalId,
        'creator': _findText(item, const ['creator', 'artist']),
        'title': _findText(item, const ['title']),
        'album': _findText(item, const ['album']),
        'artwork_url': _findText(item,
            const ['albumArtURI', 'albumArtURL', 'albumarturi', 'albumarturl']),
      };
    } catch (_) {
      return const {};
    }
  }

  int? parseDurationMs(String? duration) {
    if (duration == null || duration.isEmpty) return null;
    if (duration.toUpperCase() == 'NOT_IMPLEMENTED') return null;

    final parts = duration.split(':');
    if (parts.length < 2) return null;

    int hours = 0;
    int minutes = 0;
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

  Map<String, dynamic>? parseCoordinatorFromZoneGroupState(String body) {
    try {
      final zgDoc = _parseZoneGroupState(body);
      if (zgDoc == null) return null;

      for (final group in zgDoc.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'zonegroup')) {
        final coordinatorId = group.getAttribute('Coordinator');
        if (coordinatorId == null || coordinatorId.isEmpty) continue;

        final members = group.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'zonegroupmember')
            .toList();
        if (members.isEmpty) continue;

        final allBoost = members.every(
            (m) => (m.getAttribute('ZoneName') ?? '').toLowerCase() == 'boost');
        if (allBoost) continue;

        final groupDevices = _parseGroupDevices(members);

        for (final member in members) {
          final uuid = member.getAttribute('UUID') ?? '';
          if (uuid.toUpperCase() != coordinatorId.toUpperCase()) continue;

          final idleStateStr = member.getAttribute('IdleState');
          final idleState =
              idleStateStr != null ? int.tryParse(idleStateStr) : null;
          if (idleState != null && idleState != 0) {
            continue;
          }

          final location = member.getAttribute('Location');
          final zoneName = member.getAttribute('ZoneName') ?? 'Sonos';
          final model = member.getAttribute('ModelNumber');
          final ip = _hostFromLocation(location);
          if (ip == null || ip.isEmpty) continue;

          return {
            'ip': ip,
            'name': zoneName,
            'uuid': uuid,
            'is_coordinator': true,
            'model': model,
            'room_name': zoneName,
            'location': location,
            'idle_state': idleState,
            'group_devices': groupDevices,
          };
        }
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic>? parseDeviceFromZoneGroupStateByTargetUuid({
    required String body,
    required String targetUuid,
  }) {
    try {
      final zgDoc = _parseZoneGroupState(body);
      if (zgDoc == null) return null;

      for (final group in zgDoc.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local.toLowerCase() == 'zonegroup')) {
        final members = group.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local.toLowerCase() == 'zonegroupmember')
            .toList();
        if (members.isEmpty) continue;

        final allBoost = members.every(
            (m) => (m.getAttribute('ZoneName') ?? '').toLowerCase() == 'boost');
        if (allBoost) continue;

        final groupDevices = _parseGroupDevices(members);

        for (final member in members) {
          final uuid = member.getAttribute('UUID') ?? '';
          if (uuid.isEmpty || uuid.toUpperCase() != targetUuid) continue;

          final idleStateStr = member.getAttribute('IdleState');
          final idleState =
              idleStateStr != null ? int.tryParse(idleStateStr) : null;
          final location = member.getAttribute('Location');
          final zoneName = member.getAttribute('ZoneName') ?? 'Sonos';
          final model = member.getAttribute('ModelNumber');
          final ip = _hostFromLocation(location);
          if (ip == null || ip.isEmpty) continue;

          return {
            'ip': ip,
            'name': zoneName,
            'uuid': uuid,
            'is_coordinator': true,
            'model': model,
            'location': location,
            'idle_state': idleState,
            'room_name': zoneName,
            'group_devices': groupDevices,
          };
        }
      }
    } catch (_) {}

    return null;
  }

  xml.XmlDocument? _parseZoneGroupState(String body) {
    final outer = xml.XmlDocument.parse(body);
    final zgStateNode = outer.descendants
        .whereType<xml.XmlElement>()
        .where((e) => e.name.local.toLowerCase() == 'zonegroupstate')
        .firstOrNull;
    if (zgStateNode == null) return null;

    final innerRaw = zgStateNode.innerText.trim();
    if (innerRaw.isEmpty) return null;

    return xml.XmlDocument.parse(innerRaw);
  }

  List<Map<String, dynamic>> _parseGroupDevices(List<xml.XmlElement> members) {
    final groupDevices = <Map<String, dynamic>>[];
    for (final member in members) {
      final name = member.getAttribute('ZoneName');
      final location = member.getAttribute('Location');
      if (name != null && name.isNotEmpty) {
        groupDevices.add({
          'name': name,
          if (location != null && location.isNotEmpty) 'location': location,
        });
      }
    }
    return groupDevices;
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
        final parsed = parseDurationMs(dur);
        if (parsed != null) return parsed;
      }
    } catch (_) {}
    return null;
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

  String? _extractSpotifyTrackId(String? resText) {
    if (resText == null || resText.isEmpty) return null;
    final match = RegExp(r'((?:x-sonos-spotify:)?spotify:track:([^?&#\s]+))',
            caseSensitive: false)
        .firstMatch(resText);
    if (match == null) return null;
    return match.group(1);
  }

  String? _hostFromLocation(String? location) {
    if (location == null || location.isEmpty) return null;
    final uri = Uri.tryParse(location);
    return uri?.host;
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
