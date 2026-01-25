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
import 'package:media_display/src/services/spotify_direct_service.dart';
import 'package:media_display/src/services/service_orchestrator.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/widgets/app_header.dart';
import 'package:url_launcher/url_launcher.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? user;
  Map<String, dynamic>? settings;
  String? error;
  bool loading = true;
  bool savingSettings = false;
  bool launchingSpotify = false;
  DateTime? _lastPauseTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize the service orchestrator which handles both direct Spotify and cloud service
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Touch the orchestrator to initialize it
      ref.read(serviceOrchestratorProvider);
      // Also ensure websocket kicks off for backward compatibility
      ref.read(eventsWsProvider.notifier).connect();
    });
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _lastPauseTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _handleResume();
    }
  }

  void _handleResume() {
    if (_lastPauseTime == null) return;

    final pauseDuration = DateTime.now().difference(_lastPauseTime!);
    _lastPauseTime = null;

    // Ignore very short pauses (< 5 seconds) - likely just tab switching
    if (pauseDuration.inSeconds < 5) {
      return;
    }

    // If paused for more than threshold, force reconnect via orchestrator
    final env = ref.read(envConfigProvider);
    if (pauseDuration.inSeconds > env.wsForceReconnIdleSec) {
      ref.read(serviceOrchestratorProvider.notifier).reconnect();
    }
    // For medium pauses (5-30s), the services should still be connected
    // and will handle token refresh automatically - no action needed
  }

  Future<void> _loadData() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final me = await ref.read(userServiceProvider).fetchMe();
      final userId = me['id']?.toString() ?? '';
      if (userId.isEmpty) throw Exception('User ID not found');
      final s =
          await ref.read(settingsServiceProvider).fetchSettingsForUser(userId);
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
    final userId = user?['id']?.toString() ?? '';
    if (userId.isEmpty) {
      setState(() => error = 'User ID not available');
      return;
    }
    setState(() {
      savingSettings = true;
      error = null;
    });
    try {
      final next = await ref
          .read(settingsServiceProvider)
          .updateSettingsForUser(userId, partial);
      if (!mounted) return;
      setState(() => settings = next);

      // Update the orchestrator with new service settings
      final spotifyEnabled = next['spotify_enabled'] == true;
      final sonosEnabled = next['sonos_enabled'] == true;
      ref.read(serviceOrchestratorProvider.notifier).updateServicesEnabled(
            spotifyEnabled: spotifyEnabled,
            sonosEnabled: sonosEnabled,
          );

      // Also send config to WebSocket for backward compatibility
      final ws = ref.read(eventsWsProvider.notifier);
      await ws.sendConfig();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => savingSettings = false);
    }
  }

  Future<void> _logout(BuildContext context) async {
    // Note: stopPolling() is called automatically by events_ws_service auth listener
    await ref.read(authServiceProvider).logout();
    await ref.read(authStateProvider.notifier).clear();
    if (mounted) context.go('/login');
  }

  bool _hasSpotifyIdentity() {
    final identitiesRaw = user?['provider_avatar_list'];
    if (identitiesRaw is List) {
      for (final entry in identitiesRaw) {
        if (entry is Map &&
            (entry['provider']?.toString().toLowerCase() == 'spotify')) {
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
        await ref
            .read(authServiceProvider)
            .setPendingOauthRedirect(GoRouterState.of(context).uri.toString());
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
    // Service orchestrator handles starting/stopping services automatically
  }

  Future<void> _handleSonosToggle(bool enable) async {
    await _updateSettings({'sonos_enabled': enable});
  }

  @override
  Widget build(BuildContext context) {
    // Watch unified playback state from orchestrator
    final unifiedState = ref.watch(serviceOrchestratorProvider);

    // Also watch individual services for backward compatibility / fallback
    final now = ref.watch(eventsWsProvider);
    final directState = ref.watch(spotifyDirectProvider);

    // Use unified state from orchestrator if available, otherwise fall back to old logic
    final Map<String, dynamic>? effectivePayload;
    final String? effectiveProvider;
    final String? effectiveError;
    final bool effectiveConnected;
    final SpotifyPollingMode effectiveMode;
    final ServiceType? activeService;

    if (unifiedState.hasData || unifiedState.isLoading) {
      // Use orchestrator's unified state
      effectivePayload = unifiedState.track != null
          ? {
              'track': unifiedState.track,
              'playback': unifiedState.playback,
              'device': unifiedState.device,
              'provider': unifiedState.provider,
            }
          : null;
      effectiveProvider = unifiedState.provider;
      effectiveError = unifiedState.error;
      effectiveConnected = unifiedState.isConnected;
      activeService = unifiedState.activeService;
      // Map ServiceType to SpotifyPollingMode for backward compatibility
      effectiveMode = activeService == ServiceType.directSpotify
          ? SpotifyPollingMode.direct
          : (activeService?.isCloudService == true
              ? SpotifyPollingMode.fallback
              : SpotifyPollingMode.idle);
    } else {
      // Fall back to old logic during transition
      effectivePayload = directState.mode == SpotifyPollingMode.direct
          ? directState.payload
          : now.payload;
      effectiveProvider = directState.mode == SpotifyPollingMode.direct
          ? 'spotify'
          : now.provider;
      effectiveError = directState.mode == SpotifyPollingMode.direct
          ? directState.error
          : now.error;
      effectiveConnected = now.connected;
      effectiveMode = directState.mode;
      activeService = directState.mode == SpotifyPollingMode.direct
          ? ServiceType.directSpotify
          : (now.connected ? ServiceType.cloudSpotify : null);
    }

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
                      child: Text(error!,
                          style: const TextStyle(color: Color(0xFFFF8C8C))),
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
                      provider: effectiveProvider,
                      payload: effectivePayload,
                      error: effectiveError,
                      connected: effectiveConnected,
                      mode: effectiveMode,
                      settings: settings,
                      wsRetrying: now.wsRetrying,
                      wsInCooldown: now.wsInCooldown,
                      activeService: activeService,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Welcome back',
            style: TextStyle(color: Color(0xFF9FB1D0), letterSpacing: 0.4)),
        const SizedBox(height: 6),
        Text(displayName,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        if (email.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(email, style: const TextStyle(color: Color(0xFFC2CADC))),
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
        const Text('Services',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
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
  const _NowPlayingSection({
    required this.provider,
    required this.payload,
    required this.error,
    required this.connected,
    required this.mode,
    required this.settings,
    required this.wsRetrying,
    required this.wsInCooldown,
    this.activeService,
  });
  final String? provider;
  final Map<String, dynamic>? payload;
  final String? error;
  final bool connected;
  final SpotifyPollingMode mode;
  final Map<String, dynamic>? settings;
  final bool wsRetrying;
  final bool wsInCooldown;
  final ServiceType? activeService;

  @override
  Widget build(BuildContext context) {
    final hasService = (settings?['spotify_enabled'] == true) ||
        (settings?['sonos_enabled'] == true);
    if (!hasService) {
      return const Text('Enable Spotify or Sonos to see Now Playing.',
          style: TextStyle(color: Color(0xFF9FB1D0)));
    }

    final effectiveProvider = provider ?? 'spotify';
    final artwork = _artworkUrl(payload, effectiveProvider);
    final title = _trackTitle(payload, effectiveProvider);
    final artist = _artistText(payload, effectiveProvider);
    final album = _albumText(payload, effectiveProvider);
    final deviceInfo = _deviceInfo(payload, effectiveProvider);
    final isPlaying = _isPlaying(payload);
    final isStopped = _isStopped(payload);
    final isConnected = connected && error == null;

    // Determine status text
    String statusText;
    if (isStopped) {
      statusText = 'Stopped';
    } else if (deviceInfo.primary.isNotEmpty) {
      statusText =
          '${isPlaying ? 'Now Playing' : 'Paused'} on ${deviceInfo.primary}${deviceInfo.rest.isNotEmpty ? ' +${deviceInfo.rest.length} more' : ''}';
    } else {
      statusText = isPlaying ? 'Now Playing' : 'Paused';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      statusText,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (deviceInfo.rest.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message:
                          [deviceInfo.primary, ...deviceInfo.rest].join('\n'),
                      preferBelow: false,
                      child: const Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Color(0xFF9FB1D0),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            _EqualizerIndicator(
              isConnected: isConnected,
              isPlaying: isPlaying,
              mode: mode,
              provider: effectiveProvider,
              wsRetrying: wsRetrying,
              wsInCooldown: wsInCooldown,
              activeService: activeService,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (!connected && error != null)
          const _AnimatedSkeletonNowPlaying()
        else if (error != null)
          Text(error!, style: const TextStyle(color: Color(0xFFFF8C8C)))
        else if (payload == null)
          _skeletonNowPlaying()
        else if (isStopped)
          // Stopped state - show minimal UI with just the music icon
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Artwork(url: ''),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No active playback',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF9FB1D0).withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Start playing on Spotify to see what\'s playing',
                      style: TextStyle(
                        color: const Color(0xFF9FB1D0).withValues(alpha: 0.5),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          )
        else ...[
          Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Artwork(url: artwork),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title.isNotEmpty ? title : 'Unknown Track',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        if (artist.isNotEmpty)
                          Text(artist,
                              style: const TextStyle(color: Color(0xFFC2CADC))),
                        if (album.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(album,
                              style: const TextStyle(
                                  color: Color(0xFF9FB1D0), fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Text(
                  effectiveProvider.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    color: const Color(0xFF9FB1D0).withValues(alpha: 0.3),
                    fontWeight: FontWeight.w600,
                  ),
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
        gradient: const LinearGradient(
            colors: [Color(0xFF24324F), Color(0xFF1A2338)]),
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
  State<_AnimatedSkeletonNowPlaying> createState() =>
      _AnimatedSkeletonNowPlayingState();
}

class _AnimatedSkeletonNowPlayingState
    extends State<_AnimatedSkeletonNowPlaying>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _alpha;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
    _alpha = Tween<double>(begin: 0.45, end: 0.9)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
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
  const _EqualizerIndicator({
    required this.isConnected,
    required this.isPlaying,
    required this.mode,
    required this.provider,
    required this.wsRetrying,
    required this.wsInCooldown,
    this.activeService,
  });
  final bool isConnected;
  final bool isPlaying;
  final SpotifyPollingMode mode;
  final String? provider;
  final bool wsRetrying;
  final bool wsInCooldown;
  final ServiceType? activeService;

  @override
  State<_EqualizerIndicator> createState() => _EqualizerIndicatorState();
}

class _EqualizerIndicatorState extends State<_EqualizerIndicator>
    with SingleTickerProviderStateMixin {
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
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100));
    _blinkController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _blink = Tween<double>(begin: 0.55, end: 1.0).animate(
        CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut));
    final rnd = math.Random();
    _phases = List.generate(3, (_) => rnd.nextDouble() * math.pi * 2);
    _speeds = List.generate(
        3, (_) => 0.8 + rnd.nextDouble() * 0.7); // vary speeds per bar
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
    // Determine color based on active service and connection state:
    // - direct_spotify active → Green (#22C55E)
    // - cloud_spotify active → Light Blue (#38BDF8)
    // - cloud_sonos active → Cyan (#06B6D4)
    // - Not connected / retrying → blink appropriate color
    // - In cooldown → blink red
    // - No active service → red
    final Color color;
    final bool shouldBlink;

    // Color definitions
    const greenColor = Color(0xFF22C55E); // Direct Spotify
    const lightBlueColor = Color(0xFF38BDF8); // Cloud Spotify
    const cyanColor = Color(0xFF06B6D4); // Cloud Sonos
    const redColor = Color(0xFFEF4444); // Disconnected/Error
    const purpleColor =
        Color.fromARGB(255, 163, 92, 211); // Retrying without playback

    /// Get color for a service type
    Color getServiceColor(ServiceType? service) {
      switch (service) {
        case ServiceType.directSpotify:
          return greenColor;
        case ServiceType.cloudSpotify:
          return lightBlueColor;
        case ServiceType.cloudSonos:
          return cyanColor;
        case null:
          return redColor;
      }
    }

    if (!widget.isConnected) {
      // Not connected - check retry state
      if (widget.wsInCooldown) {
        // In cooldown - blink red
        color = redColor;
        shouldBlink = true;
      } else if (widget.wsRetrying) {
        // Actively retrying - color depends on playback state
        if (widget.isPlaying) {
          // Use the active service color while retrying
          color = getServiceColor(widget.activeService);
        } else {
          color = purpleColor; // Not playing while retrying
        }
        shouldBlink = true;
      } else {
        // Not retrying at all (exhausted or initial) - blink red
        color = redColor;
        shouldBlink = true;
      }
    } else {
      // Connected - determine color based on active service
      if (widget.activeService != null) {
        color = getServiceColor(widget.activeService);
      } else {
        // Fallback to old logic for backward compatibility
        final hasActiveProvider =
            widget.provider != null && widget.provider!.isNotEmpty;

        if (widget.mode == SpotifyPollingMode.direct) {
          color = greenColor;
        } else if (hasActiveProvider ||
            widget.mode == SpotifyPollingMode.fallback) {
          color = lightBlueColor;
        } else {
          color = redColor;
        }
      }
      shouldBlink = !widget.isPlaying;
    }

    return SizedBox(
      width: 32,
      height: 22,
      child: AnimatedBuilder(
        animation: Listenable.merge([_controller, _blinkController]),
        builder: (context, _) {
          final t = _controller.value;
          final blinking = shouldBlink;
          final opacity = blinking ? _blink.value : 1.0;
          return Opacity(
            opacity: opacity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: List.generate(3, (i) {
                final h = (widget.isConnected && widget.isPlaying)
                    ? _minHeight +
                        (_maxHeight - _minHeight) *
                            (0.35 +
                                0.65 *
                                    ((math.sin((t * 2 * math.pi * _speeds[i]) +
                                                _phases[i]) +
                                            1) /
                                        2))
                    : _minHeight;
                return Container(
                  width: 4,
                  height: h,
                  margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                          color: color.withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 1.5),
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

Widget _toggleRow(
    {required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged}) {
  return Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: const TextStyle(color: Color(0xFF9FB1D0), fontSize: 12)),
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
  return (user?['display_name'] ??
          user?['name'] ??
          user?['username'] ??
          user?['email'] ??
          'User')
      .toString();
}

bool _isPlaying(Map<String, dynamic>? payload) {
  if (payload == null) return false;
  final playback = payload['playback'];
  if (playback is Map) {
    final v = playback['is_playing'];
    if (v is bool) return v;
  }
  return false;
}

bool _isStopped(Map<String, dynamic>? payload) {
  if (payload == null) return false;
  final playback = payload['playback'];
  if (playback is Map) {
    return playback['status'] == 'stopped';
  }
  return false;
}

class _DeviceInfo {
  const _DeviceInfo({required this.primary, required this.rest});
  final String primary;
  final List<String> rest;
}

_DeviceInfo _deviceInfo(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return const _DeviceInfo(primary: '', rest: []);

  final device = payload['device'];
  if (device is! Map) return const _DeviceInfo(primary: '', rest: []);

  final groupDevices = device['group_devices'];
  if (groupDevices is List && groupDevices.isNotEmpty) {
    final names = groupDevices
        .map((g) {
          if (g is String) return g;
          if (g is Map && g['name'] is String) return g['name'] as String;
          return null;
        })
        .whereType<String>()
        .toList();
    if (names.isNotEmpty) {
      final primary = names.first;
      final rest = names.skip(1).toList();
      return _DeviceInfo(primary: primary, rest: rest);
    }
  }

  if (device['name'] is String) {
    return _DeviceInfo(primary: device['name'] as String, rest: const []);
  }

  return const _DeviceInfo(primary: '', rest: []);
}

String _trackTitle(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final track = payload['track'];
  if (track is Map && track['title'] is String) {
    return track['title'] as String;
  }
  return '';
}

String _artistText(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final track = payload['track'];
  if (track is Map && track['artist'] is String) {
    return track['artist'] as String;
  }
  return '';
}

String _albumText(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final track = payload['track'];
  if (track is Map && track['album'] is String) {
    return track['album'] as String;
  }
  return '';
}

String _artworkUrl(Map<String, dynamic>? payload, String provider) {
  if (payload == null) return '';
  final track = payload['track'];
  if (track is Map && track['artwork_url'] is String) {
    return track['artwork_url'] as String;
  }
  return '';
}
