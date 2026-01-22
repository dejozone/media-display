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
import 'package:media_display/src/services/avatar_service.dart';
import 'package:media_display/src/services/settings_service.dart';
import 'package:media_display/src/models/avatar.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/widgets/app_header.dart';
import 'package:url_launcher/url_launcher.dart';

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  Map<String, dynamic>? user;
  Map<String, dynamic>? settings;
  bool loading = true;
  bool saving = false;
  bool showCropper = false;
  bool cropping = false;
  bool launchingSpotify = false;
  String? error;
  String? success;

  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();

  Uint8List? _pendingImageBytes;
  final CropController _cropController = CropController();

  // Callback for when child component crops an image
  Future<void> Function(Uint8List)? _onChildCropped;

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
      final userId = acc['user_id']?.toString() ?? acc['id']?.toString() ?? '';
      final s = await service.fetchSettings(userId);
      if (!mounted) return;
      user = acc;
      settings = s;
      _emailController.text = acc['email']?.toString() ?? '';
      _usernameController.text = acc['username']?.toString() ?? '';
      _displayNameController.text = acc['display_name']?.toString() ?? '';
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
    if (user == null || user?['id'] == null) {
      setState(() => error = 'User ID not available');
      return;
    }
    setState(() {
      saving = true;
      error = null;
      success = null;
    });
    try {
      final service = ref.read(accountServiceProvider);
      final userId = user!['id'].toString();
      final updated = await service.updateAccount(userId, {
        'email': _emailController.text.trim().isEmpty
            ? null
            : _emailController.text.trim(),
        'username': _usernameController.text.trim().isEmpty
            ? null
            : _usernameController.text.trim(),
        'display_name': _displayNameController.text.trim().isEmpty
            ? null
            : _displayNameController.text.trim(),
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
      final userId = user!['id'].toString();
      final updated = await service.updateService(
        userId: userId,
        service: serviceKey,
        enable: enable,
      );
      final newSettings = await service.fetchSettings(userId);

      // Update the global settings cache so home page stays in sync
      final settingsService = ref.read(settingsServiceProvider);
      await settingsService.fetchSettingsForUser(userId, forceRefresh: true);

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
      launchingSpotify = true;
      error = null;
      success = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      await auth
          .setPendingOauthRedirect(GoRouterState.of(context).uri.toString());
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
      if (mounted) {
        setState(() {
          saving = false;
          launchingSpotify = false;
        });
      }
    }
  }

  Future<void> _handleSpotifyToggle(bool enable) async {
    final hasIdentity = _providerAvatarList(user)
        .any((e) => (e['provider']?.toString().toLowerCase() == 'spotify'));
    if (enable && !hasIdentity) {
      await _startSpotifyEnable();
      return;
    }

    // Show confirmation dialog when disabling
    if (!enable) {
      final confirmed = await _showDisableServiceDialog('Spotify');
      if (confirmed != true) return;
    }

    await _toggleService('spotify', enable);
  }

  Future<void> _handleSonosToggle(bool enable) async {
    // Show confirmation dialog when disabling
    if (!enable) {
      final confirmed = await _showDisableServiceDialog('Sonos');
      if (confirmed != true) return;
    }

    await _toggleService('sonos', enable);
  }

  Future<bool?> _showDisableServiceDialog(String serviceName) async {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disable $serviceName'),
        content: Text(
          'This will permanently disable $serviceName integration. You can re-enable it later from this page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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

      // Child component always provides a handler
      if (_onChildCropped != null) {
        await _onChildCropped!(data);
        setState(() {
          showCropper = false;
          cropping = false;
          _pendingImageBytes = null;
          _onChildCropped = null;
        });
        return;
      }

      // Fallback: should not happen as child always passes handler
      setState(() {
        error = 'Upload handler not provided';
        cropping = false;
      });
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

  void _closeCropper() {
    setState(() {
      showCropper = false;
      cropping = false;
      _pendingImageBytes = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final spotifyLinked = _providerAvatarList(user)
        .any((e) => (e['provider']?.toString().toLowerCase() == 'spotify'));
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
                          child: Text(error!,
                              style: const TextStyle(color: Color(0xFFFF8C8C))),
                        ),
                      if (success != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(success!,
                              style: const TextStyle(color: Color(0xFF9FB1D0))),
                        ),
                      _glassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Profile',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
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
                            const Text('Services',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 10),
                            _serviceToggle(
                              label: 'Spotify',
                              value: spotifyLinked,
                              onChanged: (saving || launchingSpotify)
                                  ? null
                                  : _handleSpotifyToggle,
                            ),
                            const SizedBox(height: 10),
                            _serviceToggle(
                              label: 'Sonos',
                              value: sonosEnabled,
                              onChanged: saving ? null : _handleSonosToggle,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _AvatarManagementSection(
                        userId: user?['user_id']?.toString() ??
                            user?['id']?.toString() ??
                            '',
                        onAvatarChanged: _load,
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
          border: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF2A3347))),
        ),
      ),
    ],
  );
}

Widget _serviceToggle(
    {required String label,
    required bool value,
    required ValueChanged<bool>? onChanged}) {
  return Row(
    children: [
      Expanded(
          child:
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
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
                  const Text('Crop avatar',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                      TextButton(
                          onPressed: cropping ? null : onCancel,
                          child: const Text('Cancel')),
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

// Avatar Management Section Widget
class _AvatarManagementSection extends ConsumerStatefulWidget {
  const _AvatarManagementSection({
    required this.userId,
    required this.onAvatarChanged,
  });

  final String userId;
  final VoidCallback onAvatarChanged;

  @override
  ConsumerState<_AvatarManagementSection> createState() =>
      _AvatarManagementSectionState();
}

class _AvatarManagementSectionState
    extends ConsumerState<_AvatarManagementSection> {
  bool _uploading = false;
  String? _error;
  String _pendingFilename = 'avatar.jpg';

  static const Set<String> _allowedExtensions = {
    'png',
    'jpg',
    'jpeg',
    'bmp',
    'heic',
    'heif'
  };

  String _extensionFromName(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  Future<void> _pickAndUploadAvatar() async {
    if (widget.userId.isEmpty) return;

    final avatarsAsync = ref.read(avatarsProvider(widget.userId));
    final currentCount = avatarsAsync.value?.length ?? 0;
    final maxAvatars = ref.read(envConfigProvider).maxAvatarsPerUser;

    if (currentCount >= maxAvatars) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Maximum of $maxAvatars avatars reached. Delete one first.')),
        );
      }
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
    });

    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );

      if (pickedFile == null) {
        if (mounted) setState(() => _uploading = false);
        return;
      }

      final ext = _extensionFromName(pickedFile.name);
      if (!_allowedExtensions.contains(ext)) {
        if (mounted) {
          setState(() {
            _error = 'Unsupported file type. Use PNG, JPG, BMP, or HEIC.';
            _uploading = false;
          });
        }
        return;
      }

      final rawBytes = await pickedFile.readAsBytes();
      if (rawBytes.isEmpty) {
        if (mounted) {
          setState(() {
            _error = 'Selected image is empty.';
            _uploading = false;
          });
        }
        return;
      }

      // Store filename and delegate to parent page's crop dialog
      setState(() {
        _pendingFilename = 'avatar.${ext == 'jpeg' ? 'jpg' : ext}';
        _uploading = false;
      });

      // Show crop dialog at page level by finding ancestor
      if (mounted &&
          context.findAncestorStateOfType<_AccountSettingsPageState>() !=
              null) {
        final pageState =
            context.findAncestorStateOfType<_AccountSettingsPageState>()!;
        pageState.setState(() {
          pageState._pendingImageBytes = rawBytes;
          pageState.showCropper = true;
          // Pass our crop handler to parent
          pageState._onChildCropped = _handleCropped;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _uploading = false;
        });
      }
    }
  }

  Future<void> _handleCropped(Uint8List croppedBytes) async {
    setState(() {
      _error = null;
    });

    try {
      final decoded = img.decodeImage(croppedBytes);
      if (decoded == null) {
        throw Exception('Could not decode cropped image');
      }
      final resized = img.copyResize(decoded,
          width: 150, height: 150, interpolation: img.Interpolation.average);

      final isPng = _pendingFilename.endsWith('.png');
      final encoded =
          isPng ? img.encodePng(resized) : img.encodeJpg(resized, quality: 92);

      final operations = ref.read(avatarOperationsProvider);
      await operations.uploadAvatarBytes(
        widget.userId,
        Uint8List.fromList(encoded),
        _pendingFilename,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Avatar uploaded successfully')),
        );
        widget.onAvatarChanged();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _selectAvatar(Avatar avatar) async {
    if (avatar.isSelected) return;

    try {
      final operations = ref.read(avatarOperationsProvider);
      await operations.selectAvatar(widget.userId, avatar.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Avatar selected')),
        );
        widget.onAvatarChanged();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to select avatar: $e')),
        );
      }
    }
  }

  Future<void> _deleteAvatar(Avatar avatar) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Avatar'),
        content: Text(
          avatar.isSelected
              ? 'Delete your selected avatar? You\'ll see a placeholder until you select another.'
              : 'Delete this avatar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final operations = ref.read(avatarOperationsProvider);
      await operations.deleteAvatar(widget.userId, avatar.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Avatar deleted')),
        );
        widget.onAvatarChanged();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.userId.isEmpty) {
      return _glassCard(
        child: const Text('Loading avatar management...'),
      );
    }

    final avatarsAsync = ref.watch(avatarsProvider(widget.userId));
    final maxAvatars = ref.watch(envConfigProvider).maxAvatarsPerUser;

    return _glassCard(
      child: avatarsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Avatar',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text('Error loading avatars: $error',
                style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => ref.invalidate(avatarsProvider(widget.userId)),
              child: const Text('Retry'),
            ),
          ],
        ),
        data: (avatars) {
          final selectedAvatar = avatars.where((a) => a.isSelected).firstOrNull;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Avatar',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    '${avatars.length}/$maxAvatars',
                    style: const TextStyle(color: Color(0xFF9FB1D0)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                selectedAvatar != null
                    ? 'Tap an avatar to select it'
                    : 'No avatar selected',
                style: const TextStyle(color: Color(0xFF9FB1D0), fontSize: 12),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              if (avatars.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      children: [
                        Icon(Icons.account_circle_outlined,
                            size: 60,
                            color: Colors.white.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        const Text('No avatars yet',
                            style: TextStyle(color: Color(0xFF9FB1D0))),
                      ],
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Calculate size for circular avatars (max 100px)
                    final availableWidth = constraints.maxWidth;
                    final spacing = 12.0;
                    final crossAxisCount =
                        (availableWidth / 112).floor().clamp(3, 6);
                    final itemSize =
                        ((availableWidth - (spacing * (crossAxisCount - 1))) /
                                crossAxisCount)
                            .clamp(60.0, 100.0);

                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        childAspectRatio: 1.0,
                      ),
                      itemCount: avatars.length,
                      itemBuilder: (context, index) {
                        final avatar = avatars[index];
                        return _AvatarGridItem(
                          avatar: avatar,
                          size: itemSize,
                          onTap: () => _selectAvatar(avatar),
                          onDelete: () => _deleteAvatar(avatar),
                        );
                      },
                    );
                  },
                ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _uploading || avatars.length >= maxAvatars
                    ? null
                    : _pickAndUploadAvatar,
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload, size: 18),
                label: Text(_uploading ? 'Uploading...' : 'Upload New Avatar'),
              ),
              if (avatars.length >= maxAvatars)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Max $maxAvatars avatars. Delete one to upload more.',
                    style:
                        const TextStyle(color: Color(0xFFFF8C8C), fontSize: 11),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AvatarGridItem extends StatelessWidget {
  const _AvatarGridItem({
    required this.avatar,
    required this.size,
    required this.onTap,
    required this.onDelete,
  });

  final Avatar avatar;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final iconSize = (size * 0.14).clamp(10.0, 14.0);
    final buttonSize = (size * 0.22).clamp(18.0, 22.0);
    final buttonPadding = (size * 0.06).clamp(4.0, 6.0);

    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF1A2333),
          border: Border.all(
            color: avatar.isSelected
                ? const Color(0xFF5AC8FA)
                : Colors.white.withValues(alpha: 0.08),
            width: avatar.isSelected ? 2.5 : 1.5,
          ),
        ),
        child: Stack(
          children: [
            // Avatar image
            ClipOval(
              child: SizedBox.expand(
                child: avatar.url.isNotEmpty
                    ? Image.network(
                        avatar.url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.broken_image,
                            size: size * 0.4, color: const Color(0xFF9FB1D0)),
                      )
                    : Icon(Icons.account_circle,
                        size: size * 0.5, color: const Color(0xFF9FB1D0)),
              ),
            ),
            // Provider indicator badge at bottom
            if (avatar.isProviderAvatar)
              Positioned(
                bottom: buttonPadding,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: buttonPadding * 1.5,
                      vertical: buttonPadding * 0.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF34D399).withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.cloud,
                      size: iconSize,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            // Selected indicator
            if (avatar.isSelected)
              Positioned(
                top: buttonPadding,
                right: buttonPadding,
                child: Container(
                  width: buttonSize,
                  height: buttonSize,
                  decoration: BoxDecoration(
                    color: const Color(0xFF5AC8FA),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.check, size: iconSize, color: Colors.white),
                ),
              ),
            // Delete button (hidden for provider avatars)
            if (!avatar.isProviderAvatar)
              Positioned(
                top: buttonPadding,
                left: buttonPadding,
                child: InkWell(
                  onTap: onDelete,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: buttonSize,
                    height: buttonSize,
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.95),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child:
                        Icon(Icons.delete, size: iconSize, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
