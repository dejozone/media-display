import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/avatar_service.dart';

class AppHeader extends ConsumerWidget {
  const AppHeader({
    super.key,
    required this.user,
    required this.onAccount,
    this.onHome,
    this.onLogout,
    this.title = 'Media Display',
    this.subtitle,
  });

  final Map<String, dynamic>? user;
  final VoidCallback onAccount;
  final VoidCallback? onHome;
  final VoidCallback? onLogout;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = _displayName(user);
    final initials = displayName.isNotEmpty
        ? displayName.trim().characters.first.toUpperCase()
        : 'U';

    // Try to get selected avatar from new avatar service
    final userId = user?['user_id']?.toString() ?? '';
    final selectedAvatar =
        userId.isNotEmpty ? ref.watch(selectedAvatarProvider(userId)) : null;

    // Fall back to old method if avatar service hasn't loaded yet
    final avatarUrl = selectedAvatar?.url ?? _avatarUrl(user);

    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(subtitle!,
                    style: const TextStyle(color: Color(0xFF9FB1D0))),
              ),
          ],
        ),
        const Spacer(),
        const SizedBox(width: 8),
        if (onHome != null)
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A2333),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: IconButton(
              tooltip: 'Home',
              onPressed: onHome,
              icon: const Icon(Icons.home_outlined),
            ),
          ),
        if (onLogout != null) ...[
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A2333),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: IconButton(
              tooltip: 'Logout',
              onPressed: onLogout,
              icon: const Icon(Icons.logout),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Tooltip(
          message: displayName,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onAccount,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2333),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Center(
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFF1F2A44),
                  backgroundImage:
                      avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                  child: avatarUrl.isEmpty
                      ? Text(initials,
                          style: const TextStyle(
                              color: Color(0xFFC2CADC),
                              fontWeight: FontWeight.w700))
                      : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _displayName(Map<String, dynamic>? user) {
  return (user?['display_name'] ??
          user?['name'] ??
          user?['username'] ??
          user?['email'] ??
          'User')
      .toString();
}

String _avatarUrl(Map<String, dynamic>? user) {
  if (user == null) return '';
  String pick(dynamic v) {
    if (v is String) return v.trim();
    return '';
  }

  final direct = [
    user['avatar_url'],
    user['avatarUrl'],
    user['avatar'],
    user['photoUrl'],
  ].map(pick).firstWhere((v) => v.isNotEmpty, orElse: () => '');
  if (direct.isNotEmpty) return direct;

  // Prefer the DB-chosen identity avatar (is_selected) and avoid pulling provider avatars directly.
  final avatarList = user['provider_avatar_list'];
  if (avatarList is List) {
    final selected = avatarList.whereType<Map>().firstWhere(
        (p) => p['is_selected'] == true && pick(p['avatar_url']).isNotEmpty,
        orElse: () => {});
    final selectedUrl = pick(selected['avatar_url']);
    if (selectedUrl.isNotEmpty) return selectedUrl;

    for (final entry in avatarList.whereType<Map>()) {
      final url = pick(entry['avatar_url']);
      if (url.isNotEmpty) return url;
    }
  }

  return '';
}
