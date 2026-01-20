import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/account_service.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/widgets/app_header.dart';
import 'package:url_launcher/url_launcher.dart';

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  Map<String, dynamic>? user;
  Map<String, dynamic>? settings;
  bool loading = true;
  bool saving = false;
  bool avatarSaving = false;
  String? error;
  String? success;

  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _avatarController = TextEditingController();

  String? selectedProvider;
  String? selectedAvatar;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _usernameController.dispose();
    _displayNameController.dispose();
    _avatarController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
      success = null;
    });
    try {
      final service = ref.read(accountServiceProvider);
      final acc = await service.fetchAccount();
      final s = await service.fetchSettings();
      if (!mounted) return;
      user = acc;
      settings = s;
      _emailController.text = acc['email']?.toString() ?? '';
      _usernameController.text = acc['username']?.toString() ?? '';
      _displayNameController.text = acc['display_name']?.toString() ?? '';
      selectedProvider = acc['provider_selected']?.toString() ?? acc['provider']?.toString();
      selectedAvatar = acc['avatar_url']?.toString() ?? _providerAvatarList(acc).firstWhere(
        (p) => p['is_selected'] == true && p['avatar_url'] != null,
        orElse: () => {},
      )['avatar_url']?.toString();
      _avatarController.text = selectedAvatar ?? '';
    } catch (e) {
      if (!mounted) return;
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> _providerAvatarList(Map<String, dynamic>? acc) {
    final list = acc?['provider_avatar_list'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((entry) => entry.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }
    return const [];
  }

  Future<void> _saveProfile() async {
    setState(() {
      saving = true;
      error = null;
      success = null;
    });
    try {
      final service = ref.read(accountServiceProvider);
      final updated = await service.updateAccount({
        'email': _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
        'username': _usernameController.text.trim().isEmpty ? null : _usernameController.text.trim(),
        'display_name': _displayNameController.text.trim().isEmpty ? null : _displayNameController.text.trim(),
      });
      if (!mounted) return;
      user = updated;
      success = 'Saved';
    } catch (e) {
      if (!mounted) return;
      error = e.toString();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _toggleService(String serviceKey, bool enable) async {
    if (user == null || user?['id'] == null) return;
    setState(() {
      saving = true;
      error = null;
      success = null;
    });
    try {
      final service = ref.read(accountServiceProvider);
      final updated = await service.updateService(
        userId: user!['id'].toString(),
        service: serviceKey,
        enable: enable,
      );
      final newSettings = await service.fetchSettings();
      if (!mounted) return;
      user = updated.isNotEmpty ? updated : user;
      settings = newSettings;
      success = enable ? 'Enabled $serviceKey' : 'Disabled $serviceKey';
    } catch (e) {
      if (!mounted) return;
      error = e.toString();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _startSpotifyEnable() async {
    setState(() {
      saving = true;
      error = null;
      success = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      final url = await auth.getSpotifyAuthUrl();
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
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _handleSpotifyToggle(bool enable) async {
    if (enable) {
      await _startSpotifyEnable();
      return;
    }
    await _toggleService('spotify', false);
  }

  Future<void> _saveAvatar() async {
    final avatar = _avatarController.text.trim();
    if (avatar.isEmpty) {
      setState(() => error = 'Enter an avatar URL or pick one');
      return;
    }
    setState(() {
      avatarSaving = true;
      error = null;
      success = null;
    });
    try {
      final service = ref.read(accountServiceProvider);
      final updated = await service.saveAvatar(
        avatarUrl: avatar,
        avatarProvider: selectedProvider,
      );
      if (!mounted) return;
      user = updated;
      success = 'Avatar saved';
    } catch (e) {
      if (!mounted) return;
      error = e.toString();
    } finally {
      if (mounted) setState(() => avatarSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatarList = _providerAvatarList(user);
    final spotifyEnabled = settings?['spotify_enabled'] == true;
    final sonosEnabled = settings?['sonos_enabled'] == true;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E1117), Color(0xFF0D1021)],
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
                  title: 'Account',
                  subtitle: 'Profile, avatar, and preferences',
                  onAccount: () => context.go('/account'),
                  onLogout: null,
                ),
                const SizedBox(height: 18),
                if (loading)
                  _glassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        _SkeletonLine(width: 180),
                        SizedBox(height: 8),
                        _SkeletonLine(width: 220),
                        SizedBox(height: 12),
                        _SkeletonLine(width: 140),
                      ],
                    ),
                  )
                else ...[
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(error!, style: const TextStyle(color: Color(0xFFFF8C8C))),
                    ),
                  if (success != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(success!, style: const TextStyle(color: Color(0xFF9FB1D0))),
                    ),
                  _glassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Profile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        _field('Email', _emailController),
                        const SizedBox(height: 12),
                        _field('Username', _usernameController),
                        const SizedBox(height: 12),
                        _field('Display name', _displayNameController),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: saving ? null : _saveProfile,
                              child: Text(saving ? 'Saving…' : 'Save'),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton(
                              onPressed: loading ? null : _load,
                              child: const Text('Reload'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _glassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Services', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        _serviceToggle(
                          label: 'Spotify',
                          value: spotifyEnabled,
                          onChanged: saving ? null : _handleSpotifyToggle,
                        ),
                        const SizedBox(height: 10),
                        _serviceToggle(
                          label: 'Sonos',
                          value: sonosEnabled,
                          onChanged: saving ? null : (v) => _toggleService('sonos', v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _glassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Avatar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Wrap(
                          runSpacing: 8,
                          spacing: 8,
                          children: avatarList.map((p) {
                            final url = p['avatar_url']?.toString() ?? '';
                            final provider = p['provider']?.toString() ?? '';
                            final active = (p['is_selected'] == true) || (provider == selectedProvider);
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  selectedProvider = provider;
                                  selectedAvatar = url;
                                  _avatarController.text = url;
                                });
                              },
                              child: Container(
                                width: 68,
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: active ? const Color(0xFF5AC8FA).withValues(alpha: 0.12) : const Color(0xFFFFFFFF).withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: active ? const Color(0xFF5AC8FA) : Colors.white.withValues(alpha: 0.12)),
                                ),
                                child: Column(
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundImage: url.isNotEmpty ? NetworkImage(url) : null,
                                      backgroundColor: const Color(0xFF1F2A44),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(provider, style: const TextStyle(fontSize: 11, color: Color(0xFF9FB1D0))),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _avatarController,
                          decoration: const InputDecoration(
                            labelText: 'Custom image URL',
                            hintText: 'https://example.com/avatar.png',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: avatarSaving ? null : _saveAvatar,
                              child: Text(avatarSaving ? 'Saving…' : 'Save avatar'),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton(
                              onPressed: () {
                                setState(() {
                                  _avatarController.clear();
                                  selectedAvatar = null;
                                });
                              },
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _glassCard({required Widget child}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF111624).withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      boxShadow: const [
        BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 10)),
      ],
    ),
    child: child,
  );
}

Widget _field(String label, TextEditingController controller) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Color(0xFF9FB1D0))),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        decoration: const InputDecoration(
          filled: true,
          fillColor: Color(0xFF1A2333),
          border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF2A3347))),
        ),
      ),
    ],
  );
}

Widget _serviceToggle({required String label, required bool value, required ValueChanged<bool>? onChanged}) {
  return Row(
    children: [
      Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
      Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: const Color(0xFF5AC8FA),
        activeTrackColor: const Color(0xFF5AC8FA).withValues(alpha: 0.35),
      ),
    ],
  );
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({this.width});
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? double.infinity,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}
