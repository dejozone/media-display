import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/events_ws_service.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/user_service.dart';
import 'package:media_display/src/widgets/app_header.dart';
import 'package:url_launcher/url_launcher.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Map<String, dynamic>? user;
  Map<String, dynamic>? settings;
  String? error;
  bool loading = true;
  bool savingSettings = false;
  bool launchingSpotify = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final me = await ref.read(userServiceProvider).fetchMe();
      final s = await ref.read(settingsServiceProvider).fetchSettings();
      if (!mounted) return;
      setState(() {
        user = me;
        settings = s;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _updateSettings(Map<String, dynamic> partial) async {
    if (savingSettings) return;
    setState(() {
      savingSettings = true;
      error = null;
    });
    try {
      final next = await ref.read(settingsServiceProvider).updateSettings(partial);
      if (!mounted) return;
      setState(() => settings = next);
      ref.read(eventsWsProvider.notifier).connect();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => savingSettings = false);
    }
  }

  Future<void> _logout(BuildContext context) async {
    await ref.read(authServiceProvider).logout();
    await ref.read(authStateProvider.notifier).clear();
    if (mounted) context.go('/login');
  }

  bool _hasSpotifyIdentity() {
    final identitiesRaw = user?['provider_avatar_list'];
    if (identitiesRaw is List) {
      for (final entry in identitiesRaw) {
        if (entry is Map && (entry['provider']?.toString().toLowerCase() == 'spotify')) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _handleSpotifyToggle(bool enable) async {
    if (enable && !_hasSpotifyIdentity()) {
      // Require OAuth linking first.
      setState(() {
        error = null;
        launchingSpotify = true;
      });
      try {
        await ref.read(authServiceProvider).setPendingOauthRedirect(GoRouterState.of(context).uri.toString());
        final url = await ref.read(authServiceProvider).getSpotifyAuthUrl();
        if (!mounted) return;
        final ok = await launchUrl(
          url,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: kIsWeb ? '_self' : null,
        );
        if (!ok && mounted) {
          setState(() => error = 'Failed to open Spotify login');
        }
      } catch (e) {
        if (mounted) setState(() => error = e.toString());
      } finally {
        if (mounted) setState(() => launchingSpotify = false);
      }
      return;
    }

    await _updateSettings({'spotify_enabled': enable});
  }

  Future<void> _handleSonosToggle(bool enable) async {
    await _updateSettings({'sonos_enabled': enable});
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(eventsWsProvider);
    final scaffold = Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0E1117),
              Color(0xFF0D1021),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppHeader(
                  user: user,
                  title: 'Media Display',
                  subtitle: 'Now Playing • Spotify & Sonos',
                  onHome: () => context.go('/home'),
                  onAccount: () => context.go('/account'),
                  onLogout: () => _logout(context),
                ),
                const SizedBox(height: 18),
                if (loading) ...[
                  _glassCard(child: _skeletonLine(width: 180)),
                  const SizedBox(height: 12),
                  _glassCard(child: _skeletonLine(width: 220)),
                  const SizedBox(height: 12),
                  _glassCard(child: _skeletonNowPlaying()),
                ] else ...[
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(error!, style: const TextStyle(color: Color(0xFFFF8C8C))),
                    ),
                  _glassCard(
                    child: _UserSummary(user: user),
                  ),
                  const SizedBox(height: 14),
                  _glassCard(
                    child: _SettingsToggles(
                      settings: settings,
                      saving: savingSettings || launchingSpotify,
                      onSpotifyChanged: _handleSpotifyToggle,
                      onSonosChanged: _handleSonosToggle,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _glassCard(
                    child: _NowPlayingSection(
                      now: now,
                      settings: settings,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return scaffold;
  }
}

class _UserSummary extends StatelessWidget {
  const _UserSummary({required this.user});
  final Map<String, dynamic>? user;

  @override
  Widget build(BuildContext context) {
    final displayName = _displayName(user);
    final email = user?['email']?.toString() ?? '';
    final provider = user?['provider']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Welcome back', style: TextStyle(color: Color(0xFF9FB1D0), letterSpacing: 0.4)),
        const SizedBox(height: 6),
        Text(displayName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        if (email.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(email, style: const TextStyle(color: Color(0xFFC2CADC))),
        ],
        if (provider.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2333),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Text('Signed in with $provider', style: const TextStyle(color: Color(0xFF9FB1D0), fontSize: 13)),
          ),
        ],
      ],
    );
  }
}

class _SettingsToggles extends StatelessWidget {
  const _SettingsToggles({
    required this.settings,
    required this.saving,
    required this.onSpotifyChanged,
    required this.onSonosChanged,
  });
  final Map<String, dynamic>? settings;
  final bool saving;
  final Future<void> Function(bool) onSpotifyChanged;
  final Future<void> Function(bool) onSonosChanged;

  @override
  Widget build(BuildContext context) {
    if (settings == null) {
      return _skeletonLine(width: 200);
    }
    final spotify = settings?['spotify_enabled'] == true;
    final sonos = settings?['sonos_enabled'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Services', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 12),
        _toggleRow(
          label: 'Spotify',
          subtitle: 'Live Now Playing and control',
          value: spotify,
          onChanged: saving ? null : (v) => onSpotifyChanged(v),
        ),
        const SizedBox(height: 10),
        _toggleRow(
          label: 'Sonos',
          subtitle: 'Fallback and group playback',
          value: sonos,
          onChanged: saving ? null : (v) => onSonosChanged(v),
        ),
        if (saving) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 4),
        ],
      ],
    );
  }
}

class _NowPlayingSection extends StatelessWidget {
  const _NowPlayingSection({required this.now, required this.settings});
  final NowPlayingState now;
  final Map<String, dynamic>? settings;

  @override
  Widget build(BuildContext context) {
    final hasService = (settings?['spotify_enabled'] == true) || (settings?['sonos_enabled'] == true);
    if (!hasService) {
      return const Text('Enable Spotify or Sonos to see Now Playing.', style: TextStyle(color: Color(0xFF9FB1D0)));
    }

    final payload = now.payload;
    final provider = now.provider ?? 'spotify';
    final artwork = _artworkUrl(payload, provider);
    final title = _trackTitle(payload, provider);
    final artist = _artistText(payload, provider);
    final album = _albumText(payload, provider);
    final device = _deviceText(payload, provider);
    final status = _statusLabel(payload, provider);
    final isPlaying = _isPlaying(payload);
    final isConnected = now.connected && now.error == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Now Playing', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            _pill(provider.toUpperCase()),
            const Spacer(),
            _EqualizerIndicator(
              isConnected: isConnected,
              isPlaying: isPlaying,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (!now.connected && now.error != null)
          const _AnimatedSkeletonNowPlaying()
        else if (now.error != null)
          Text(now.error!, style: const TextStyle(color: Color(0xFFFF8C8C)))
        else if (payload == null)
          _skeletonNowPlaying()
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Artwork(url: artwork),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.isNotEmpty ? title : 'Unknown Track', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    if (artist.isNotEmpty) Text(artist, style: const TextStyle(color: Color(0xFFC2CADC))),
                    if (album.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(album, style: const TextStyle(color: Color(0xFF9FB1D0), fontSize: 13)),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _pill(status),
                        if (device.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _pill(device),
                        ],
                        const SizedBox(width: 8),
                        _pill(isPlaying ? 'Live' : 'Paused'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 90,
      height: 90,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        
        gradient: const LinearGradient(colors: [Color(0xFF24324F), Color(0xFF1A2338)]),
        image: url.isNotEmpty
            ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
            : null,
      ),
      child: url.isEmpty
          ? const Icon(Icons.music_note, color: Color(0xFF9FB1D0))
          : null,
    );
  }
}

class _AnimatedSkeletonNowPlaying extends StatefulWidget {
  const _AnimatedSkeletonNowPlaying();

  @override
  State<_AnimatedSkeletonNowPlaying> createState() => _AnimatedSkeletonNowPlayingState();
}

class _AnimatedSkeletonNowPlayingState extends State<_AnimatedSkeletonNowPlaying> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _alpha;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
    _alpha = Tween<double>(begin: 0.45, end: 0.9).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _alpha,
      builder: (context, _) => Opacity(
        opacity: _alpha.value,
        child: _skeletonNowPlaying(),
      ),
    );
  }
}

class _EqualizerIndicator extends StatefulWidget {
  const _EqualizerIndicator({required this.isConnected, required this.isPlaying});
  final bool isConnected;
  final bool isPlaying;

  @override
  State<_EqualizerIndicator> createState() => _EqualizerIndicatorState();
}

class _EqualizerIndicatorState extends State<_EqualizerIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _blinkController;
  late final Animation<double> _blink;
  late final List<double> _phases;
  late final List<double> _speeds;

  static const double _minHeight = 6;
  static const double _maxHeight = 16;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    _blinkController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _blink = Tween<double>(begin: 0.55, end: 1.0).animate(CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut));
    final rnd = math.Random();
    _phases = List.generate(3, (_) => rnd.nextDouble() * math.pi * 2);
    _speeds = List.generate(3, (_) => 0.8 + rnd.nextDouble() * 0.7); // vary speeds per bar
    _maybeAnimate();
  }

  @override
  void didUpdateWidget(covariant _EqualizerIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeAnimate();
  }

  void _maybeAnimate() {
    if (widget.isConnected && widget.isPlaying) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
      _blinkController.stop();
      _blinkController.value = 1.0;
    } else {
      _controller.stop();
      _controller.reset();
      if (!_blinkController.isAnimating) {
        _blinkController.repeat(reverse: true);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444);

    return SizedBox(
      width: 32,
      height: 22,
      child: AnimatedBuilder(
        animation: Listenable.merge([_controller, _blinkController]),
        builder: (context, _) {
          final t = _controller.value;
          final blinking = !widget.isConnected || !widget.isPlaying;
          final opacity = blinking ? _blink.value : 1.0;
          return Opacity(
            opacity: opacity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: List.generate(3, (i) {
                final h = (widget.isConnected && widget.isPlaying)
                    ? _minHeight + (_maxHeight - _minHeight) * (0.35 + 0.65 * ((math.sin((t * 2 * math.pi * _speeds[i]) + _phases[i]) + 1) / 2))
                    : _minHeight;
                return Container(
                  width: 4,
                  height: h,
                  margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8, spreadRadius: 1.5),
                    ],
                  ),
                );
              }),
            ),
          );
        },
      ),
    );
  }
}

// ---- helpers ----

Widget _glassCard({required Widget child}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF111624).withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      boxShadow: const [
        BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 10)),
      ],
    ),
    child: child,
  );
}

Widget _pill(String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFFFFFFF).withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFFC2CADC))),
  );
}

Widget _skeletonLine({double width = 140}) {
  return Container(
    width: width,
    height: 14,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
    ),
  );
}

Widget _skeletonNowPlaying() {
  return Row(
    children: [
      Container(
        width: 90,
        height: 90,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _skeletonLine(width: 180),
            const SizedBox(height: 8),
            _skeletonLine(width: 130),
            const SizedBox(height: 8),
            _skeletonLine(width: 160),
          ],
        ),
      ),
    ],
  );
}

Widget _toggleRow({required String label, required String subtitle, required bool value, required ValueChanged<bool>? onChanged}) {
  return Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: Color(0xFF9FB1D0), fontSize: 12)),
          ],
        ),
      ),
      Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: const Color(0xFF5AC8FA),
        activeTrackColor: const Color(0xFF5AC8FA).withValues(alpha: 0.35),
      ),
    ],
  );
}

String _displayName(Map<String, dynamic>? user) {
  return (user?['display_name'] ?? user?['name'] ?? user?['username'] ?? user?['email'] ?? 'User').toString();
}

bool _isPlaying(Map<String, dynamic>? payload) {
  if (payload == null) return false;
  final v = payload['is_playing'];
  if (v is bool) return v;
  return false;
}

String _statusLabel(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return 'Waiting';
  final isPlaying = _isPlaying(payload);
  if (isPlaying) return 'Playing';
  final val = payload['status'] ?? payload['state'];
  if (val is String && val.isNotEmpty) return val;
  return 'Idle';
}

String _deviceText(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final device = payload['device'];
  if (device is Map && device['name'] is String) {
    return device['name'] as String;
  }
  final group = payload['group_devices'];
  if (group is List && group.isNotEmpty) {
    final first = group.first;
    final rest = group.length - 1;
    if (first is String) {
      return rest > 0 ? '$first +$rest more' : first;
    }
  }
  return '';
}

String _trackTitle(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final item = payload['item'];
  if (item is Map && item['name'] is String) return item['name'] as String;
  if (payload['title'] is String) return payload['title'] as String;
  if (payload['name'] is String) return payload['name'] as String;
  return '';
}

String _artistText(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final item = payload['item'];
  if (item is Map && item['artists'] is List) {
    final artists = (item['artists'] as List).whereType<Map>().map((a) => a['name']).whereType<String>().toList();
    if (artists.isNotEmpty) return artists.join(', ');
  }
  final artists = payload['artists'];
  if (artists is List) {
    final names = artists.map((e) {
      if (e is String) return e;
      if (e is Map && e['name'] is String) return e['name'] as String;
      return null;
    }).whereType<String>().toList();
    if (names.isNotEmpty) return names.join(', ');
  }
  return '';
}

String _albumText(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final item = payload['item'];
  final album = (item is Map ? item['album'] : null) ?? payload['album'];
  if (album is Map) {
    if (album['name'] is String) return album['name'] as String;
    if (album['title'] is String) return album['title'] as String;
  }
  if (album is String) return album;
  final show = item is Map ? item['show'] : null;
  if (show is Map && show['name'] is String) return show['name'] as String;
  return '';
}

String _artworkUrl(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';

  String fromImages(dynamic images) {
    if (images is List) {
      for (final img in images) {
        if (img is Map && img['url'] is String) return img['url'] as String;
        if (img is String) return img;
      }
    }
    return '';
  }

  final item = payload['item'];
  if (provider == 'sonos') {
    if (item is Map) {
      final candidates = [
        item['album_art_url'],
        item['albumArt'],
        item['album_art'],
      ];
      for (final c in candidates) {
        if (c is String && c.isNotEmpty) return c;
      }
    }
  }

  final album = (item is Map ? item['album'] : null) ?? payload['album'];
  final fromAlbum = fromImages(album is Map ? album['images'] : null);
  if (fromAlbum.isNotEmpty) return fromAlbum;

  final fromItem = fromImages(item is Map ? item['images'] : null);
  if (fromItem.isNotEmpty) return fromItem;

  final fromTop = fromImages(payload['images']);
  if (fromTop.isNotEmpty) return fromTop;

  return '';
}
