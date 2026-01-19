import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/user_service.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/services/events_ws_service.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/services/auth_state.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(eventsWsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => context.go('/account'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(authServiceProvider).logout();
              await ref.read(authStateProvider.notifier).clear();
              if (context.mounted) {
                context.go('/login');
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _UserHeader(),
            const SizedBox(height: 16),
            const _SettingsToggles(),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                title: Text(now.provider != null ? 'Now Playing (${now.provider})' : 'Now Playing'),
                subtitle: Text(now.payload != null ? now.payload.toString() : 'Waiting for data...'),
                trailing: now.connected
                    ? const Icon(Icons.circle, color: Colors.green, size: 12)
                    : const Icon(Icons.circle, color: Colors.red, size: 12),
              ),
            ),
            if (now.error != null) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(now.error!, style: const TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserHeader extends ConsumerStatefulWidget {
  const _UserHeader();
  @override
  ConsumerState<_UserHeader> createState() => _UserHeaderState();
}

class _UserHeaderState extends ConsumerState<_UserHeader> {
  Map<String, dynamic>? user;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await ref.read(userServiceProvider).fetchMe();
      if (mounted) {
        setState(() {
          user = me;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return Text('User error: $error', style: const TextStyle(color: Colors.red));
    if (user == null) return const CircularProgressIndicator();
    final displayName = user?['display_name'] ?? user?['username'] ?? user?['email'] ?? 'User';
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person)),
      title: Text(displayName.toString()),
      subtitle: Text(user?['email']?.toString() ?? ''),
    );
  }
}

class _SettingsToggles extends ConsumerStatefulWidget {
  const _SettingsToggles();
  @override
  ConsumerState<_SettingsToggles> createState() => _SettingsTogglesState();
}

class _SettingsTogglesState extends ConsumerState<_SettingsToggles> {
  Map<String, dynamic>? settings;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await ref.read(settingsServiceProvider).fetchSettings();
      if (mounted) setState(() => settings = s);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _update(Map<String, dynamic> partial) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final next = await ref.read(settingsServiceProvider).updateSettings(partial);
      if (mounted) setState(() => settings = next);
      // Reconnect websocket if needed
      ref.read(eventsWsProvider.notifier).connect();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return Text('Settings error: $error', style: const TextStyle(color: Colors.red));
    if (settings == null) return const CircularProgressIndicator();
    final spotify = settings?['spotify_enabled'] == true;
    final sonos = settings?['sonos_enabled'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Services', style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: const Text('Spotify'),
              value: spotify,
              onChanged: saving ? null : (v) => _update({'spotify_enabled': v}),
            ),
            SwitchListTile(
              title: const Text('Sonos'),
              value: sonos,
              onChanged: saving ? null : (v) => _update({'sonos_enabled': v}),
            ),
            if (saving) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
