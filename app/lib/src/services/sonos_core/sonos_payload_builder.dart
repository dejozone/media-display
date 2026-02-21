class SonosPayloadBuilder {
  const SonosPayloadBuilder._();

  static Map<String, dynamic> buildNowPlayingPayload({
    required String coordinatorIp,
    required String coordinatorId,
    required String deviceName,
    required bool coordinator,
    required String transportState,
    required Map<String, dynamic>? currentTrack,
    required Map<String, dynamic>? playlist,
    required Map<String, dynamic>? nextTrack,
    required List<Map<String, dynamic>> groupDevices,
    required int timestampMs,
  }) {
    final activeStates = {'PLAYING', 'TRANSITIONING', 'BUFFERING'};
    final isPlaying = activeStates.contains(transportState);

    var playbackStatus = transportState.toLowerCase();

    final title = (currentTrack?['title'] as String?)?.trim() ?? '';
    final hasTitle = title.isNotEmpty;

    if (!hasTitle && !isPlaying) {
      playbackStatus = 'stopped';
    }

    final artistsRaw = currentTrack?['artists'];
    final artists = artistsRaw is List
        ? artistsRaw.whereType<String>().toList()
        : const <String>[];

    final trackBlock = hasTitle
        ? <String, dynamic>{
            if (currentTrack != null && currentTrack['id'] != null)
              'id': currentTrack['id'],
            'title': title,
            'artist': artists.isNotEmpty ? artists.first : '',
            'album': currentTrack?['album'],
            'artwork_url': currentTrack?['artwork_url'],
            'duration_ms': currentTrack?['duration_ms'],
            'duration': currentTrack?['duration'],
            if (playlist != null) 'playlist': playlist,
          }
        : const <String, dynamic>{};

    final nextTrackBlock = nextTrack ?? const <String, dynamic>{};
    final progressMs = currentTrack?['progress_ms'] as int?;

    final deviceBlock = {
      'name': deviceName,
      'type': 'speaker',
      'group_devices': groupDevices,
      'ip': coordinatorIp,
      'uuid': coordinatorId,
      'coordinator': coordinator,
    };

    return {
      'type': 'now_playing',
      'provider': 'sonos',
      'provider_display_name': 'Sonos',
      'data': {
        'track': hasTitle ? trackBlock : null,
        'playback': {
          'is_playing': isPlaying,
          'progress_ms': progressMs,
          'timestamp': timestampMs,
          'status': playbackStatus,
          if (nextTrackBlock.isNotEmpty) 'next_track': nextTrackBlock,
        },
        'device': deviceBlock,
        'provider': 'sonos',
      },
    };
  }
}
