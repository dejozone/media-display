import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:media_display/src/services/account_service.dart';
import 'package:media_display/src/services/auth_state.dart';
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
  bool uploadingAvatar = false;
  bool showCropper = false;
  bool cropping = false;
  String? error;
  String? success;

  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _avatarController = TextEditingController();

  String? selectedProvider;
  String? selectedAvatar;
  Uint8List? _pendingImageBytes;
  String _pendingExt = 'jpg';
  final CropController _cropController = CropController();

  static const Set<String> _allowedExtensions = {'png', 'jpg', 'jpeg', 'bmp', 'heic', 'heif'};

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

  String _normalizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    final hashStripped = trimmed.split('#').first;
    return hashStripped.split('?').first;
  }

  List<Map<String, dynamic>> _updateSelectedAvatarInList(String newUrl) {
    final list = _providerAvatarList(user);
    if (list.isEmpty) {
      return list;
    }
    final norm = _normalizeUrl(newUrl);
    bool replaced = false;
    for (var i = 0; i < list.length; i++) {
      final isSel = list[i]['is_selected'] == true;
      if (isSel) {
        list[i] = {
          ...list[i].map((k, v) => MapEntry(k.toString(), v)),
          'avatar_url': newUrl,
          'is_selected': true,
        };
        replaced = true;
      } else {
        final existingNorm = _normalizeUrl(list[i]['avatar_url']?.toString() ?? '');
        if (existingNorm == norm) {
          list[i] = {
            ...list[i].map((k, v) => MapEntry(k.toString(), v)),
            'avatar_url': newUrl,
          };
          replaced = true;
        }
      }
    }
    if (!replaced) {
      list.add({
        'avatar_url': newUrl,
        'is_selected': true,
      });
    }
    return list;
  }

  List<Map<String, dynamic>> _avatarListWithCurrent() {
    final ordered = <String, Map<String, dynamic>>{}; // normalizedUrl -> entry

    void upsert(String url, {bool selected = false}) {
      final norm = _normalizeUrl(url);
      if (norm.isEmpty) return;

      final existing = ordered[norm];
      ordered[norm] = {
        ...?existing,
        'avatar_url': url,
        'is_selected': (existing?['is_selected'] == true) || selected,
      };
    }

    for (final entry in _providerAvatarList(user)) {
      final url = entry['avatar_url']?.toString() ?? '';
      upsert(
        url,
        selected: entry['is_selected'] == true,
      );
    }

    if (selectedAvatar?.isNotEmpty == true) {
      upsert(selectedAvatar!, selected: true);
    }

    final currentRaw = _avatarController.text.trim();
    final normalizedCurrent = _normalizeUrl(currentRaw);
    if (normalizedCurrent.isNotEmpty && selectedAvatar?.isNotEmpty != true) {
      // Only consider the raw text field when we don't already have a selected avatar.
      upsert(currentRaw);
    }

    // Enforce a single selected avatar, preferring selectedAvatar, then currentRaw, then any backend-selected entry.
    String? selectedNorm;
    if (selectedAvatar?.isNotEmpty == true) {
      selectedNorm = _normalizeUrl(selectedAvatar!);
    } else if (normalizedCurrent.isNotEmpty) {
      selectedNorm = normalizedCurrent;
    } else {
      selectedNorm = ordered.entries.firstWhere(
        (e) => e.value['is_selected'] == true,
        orElse: () => MapEntry('', <String, dynamic>{}),
      ).key;
    }

    if (selectedNorm != null && selectedNorm.isNotEmpty) {
      ordered.updateAll((_, value) => {
            ...value,
            'is_selected': false,
          });
      if (ordered.containsKey(selectedNorm)) {
        ordered[selectedNorm] = {
          ...ordered[selectedNorm]!,
          'is_selected': true,
        };
      }
    }

    return ordered.values.toList();
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
      final updatedProvider = updated['provider_selected']?.toString() ?? updated['provider']?.toString() ?? selectedProvider;
      final backendUrl = updated['avatar_url']?.toString() ?? avatar;
      final displayUrl = _cacheBustedUrl(backendUrl);
      final updatedProviderAvatars = _updateSelectedAvatarInList(displayUrl);
      user = {
        ...?updated,
        'avatar_url': displayUrl,
        'provider_avatar_list': updatedProviderAvatars,
      };
      selectedProvider = updatedProvider;
      selectedAvatar = displayUrl;
      _avatarController.text = backendUrl; // keep raw URL for edits
      success = 'Avatar saved';
    } catch (e) {
      if (!mounted) return;
      error = e.toString();
    } finally {
      if (mounted) setState(() => avatarSaving = false);
    }
  }

  String _extensionFromName(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  String _cacheBustedUrl(String url) {
    if (url.isEmpty) return '';
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}v=${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _selectAndUploadAvatar() async {
    setState(() {
      uploadingAvatar = true;
      error = null;
      success = null;
    });
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery, requestFullMetadata: false);
      if (picked == null) {
        if (mounted) setState(() => uploadingAvatar = false);
        return;
      }

      final ext = _extensionFromName(picked.name);
      if (!_allowedExtensions.contains(ext)) {
        if (mounted) {
          setState(() {
            error = 'Unsupported file type. Use PNG, JPG, BMP, or HEIC.';
            uploadingAvatar = false;
          });
        }
        return;
      }

      final rawBytes = await picked.readAsBytes();
      if (rawBytes.isEmpty) {
        if (mounted) {
          setState(() {
            error = 'Selected image is empty.';
            uploadingAvatar = false;
          });
        }
        return;
      }

      setState(() {
        _pendingImageBytes = rawBytes;
        _pendingExt = (ext == 'png' || ext == 'jpg' || ext == 'jpeg') ? (ext == 'jpeg' ? 'jpg' : ext) : 'jpg';
        showCropper = true;
        uploadingAvatar = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        uploadingAvatar = false;
      });
    }
  }

  Future<void> _handleCropResult(CropResult result) async {
    if (result is CropSuccess) {
      final data = result.croppedImage;
      if (data.isEmpty) {
        setState(() {
          error = 'Crop failed to produce image data';
          cropping = false;
        });
        return;
      }
      await _handleCropped(data);
      return;
    }

    if (result is CropFailure) {
      if (!mounted) return;
      setState(() {
        error = result.cause.toString();
        cropping = false;
      });
    }
  }

  Future<void> _handleCropped(Uint8List croppedBytes) async {
    setState(() {
      cropping = true;
      error = null;
      success = null;
    });
    try {
      final decoded = img.decodeImage(croppedBytes);
      if (decoded == null) {
        throw Exception('Could not decode cropped image');
      }
      final resized = img.copyResize(decoded, width: 150, height: 150, interpolation: img.Interpolation.average);
      final targetExt = _pendingExt;
      final encoded = targetExt == 'png'
          ? img.encodePng(resized)
          : img.encodeJpg(resized, quality: 92);

      final service = ref.read(accountServiceProvider);
      final url = await service.uploadAvatarBytes(bytes: Uint8List.fromList(encoded), filename: 'avatar.$targetExt');
      if (!mounted) return;
      if (url.isEmpty) {
        setState(() {
          error = 'Failed to upload avatar';
          cropping = false;
        });
        return;
      }

      final displayUrl = _cacheBustedUrl(url);

      setState(() {
        final updatedProviderAvatars = _updateSelectedAvatarInList(displayUrl);
        user = {
          ...?user,
          'avatar_url': displayUrl,
          'provider_avatar_list': updatedProviderAvatars,
        };
        selectedProvider = selectedProvider ?? 'custom';
        selectedAvatar = displayUrl;
        _avatarController.text = url; // keep raw URL for saving
        success = 'Avatar updated';
        showCropper = false;
        cropping = false;
        _pendingImageBytes = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        cropping = false;
      });
    }
  }

  void _closeCropper() {
    setState(() {
      showCropper = false;
      cropping = false;
      _pendingImageBytes = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final avatarList = _avatarListWithCurrent();
    final spotifyEnabled = settings?['spotify_enabled'] == true;
    final sonosEnabled = settings?['sonos_enabled'] == true;

    return Scaffold(
      body: Stack(
        children: [
          Container(
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
                      onHome: () => context.go('/home'),
                      onAccount: () => context.go('/account'),
                      onLogout: () async {
                        await ref.read(authServiceProvider).logout();
                        await ref.read(authStateProvider.notifier).clear();
                        if (mounted) context.go('/login');
                      },
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
                                final active = (p['is_selected'] == true) || (_normalizeUrl(url) == _normalizeUrl(selectedAvatar ?? ''));
                                return GestureDetector(
                                  onTap: () {
                                    setState(() {
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
                                  onPressed: uploadingAvatar ? null : _selectAndUploadAvatar,
                                  child: Text(uploadingAvatar ? 'Uploading…' : 'Upload image'),
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
          if (showCropper && _pendingImageBytes != null)
            Positioned.fill(
              child: _CropDialog(
                controller: _cropController,
                bytes: _pendingImageBytes!,
                onCancel: _closeCropper,
                onCrop: _handleCropResult,
                cropping: cropping,
              ),
            ),
        ],
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

class _CropDialog extends StatelessWidget {
  const _CropDialog({
    required this.controller,
    required this.bytes,
    required this.onCancel,
    required this.onCrop,
    required this.cropping,
  });

  final CropController controller;
  final Uint8List bytes;
  final VoidCallback onCancel;
  final ValueChanged<CropResult> onCrop;
  final bool cropping;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: Material(
            color: const Color(0xFF0F1624),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Crop avatar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 480,
                    height: 380,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Crop(
                        controller: controller,
                        image: bytes,
                        aspectRatio: 1,
                        onCropped: onCrop,
                        baseColor: const Color(0xFF0B1220),
                        maskColor: Colors.black.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: cropping ? null : onCancel, child: const Text('Cancel')),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: cropping ? null : () => controller.crop(),
                        child: Text(cropping ? 'Cropping…' : 'Crop & upload'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
