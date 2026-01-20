import 'package:flutter/material.dart';

class AppHeader extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final displayName = _displayName(user);
    final initials = displayName.isNotEmpty ? displayName.trim().characters.first.toUpperCase() : 'U';
    final avatarUrl = _avatarUrl(user);

    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(subtitle!, style: const TextStyle(color: Color(0xFF9FB1D0))),
              ),
          ],
        ),
        const Spacer(),
        const SizedBox(width: 8),
        if (onHome != null)
          IconButton(
            tooltip: 'Home',
            onPressed: onHome,
            icon: const Icon(Icons.home_outlined),
          ),
        if (onLogout != null)
          IconButton(
            tooltip: 'Logout',
            onPressed: onLogout,
            icon: const Icon(Icons.logout),
          ),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onAccount,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2333),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                Text(displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFF1F2A44),
                  backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                  child: avatarUrl.isEmpty
                      ? Text(initials, style: const TextStyle(color: Color(0xFFC2CADC), fontWeight: FontWeight.w700))
                      : null,
                ),
              ],
            ),
          ),
        ),
        
      ],
    );
  }
}

String _displayName(Map<String, dynamic>? user) {
  return (user?['display_name'] ?? user?['name'] ?? user?['username'] ?? user?['email'] ?? 'User').toString();
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

  final providerAvatars = user['provider_avatars'];
  if (providerAvatars is Map) {
    for (final val in providerAvatars.values) {
      if (val is String && val.isNotEmpty) return val;
    }
  }
  return '';
}
