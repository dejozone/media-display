/// Avatar model representing a user avatar from the API
class Avatar {
  const Avatar({
    required this.id,
    required this.userId,
    required this.url,
    required this.source,
    required this.isSelected,
    this.providerId,
    this.fileSize,
    this.mimeType,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String userId;
  final String url;
  final String source; // 'provider', 'upload', 'default'
  final bool isSelected;
  final String? providerId;
  final int? fileSize;
  final String? mimeType;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Avatar.fromJson(Map<String, dynamic> json) {
    // Helper to safely get String values
    String getString(String key, [String defaultValue = '']) {
      final value = json[key];
      if (value == null) return defaultValue;
      return value.toString();
    }

    return Avatar(
      id: getString('id'),
      userId: getString('user_id'),
      url: getString('url'),
      source: getString('source', 'upload'),
      isSelected: json['is_selected'] == true,
      providerId: json['provider_id']?.toString(),
      fileSize: json['file_size'] as int?,
      mimeType: json['mime_type']?.toString(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'url': url,
      'source': source,
      'is_selected': isSelected,
      if (providerId != null) 'provider_id': providerId,
      if (fileSize != null) 'file_size': fileSize,
      if (mimeType != null) 'mime_type': mimeType,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
    };
  }

  Avatar copyWith({
    String? id,
    String? userId,
    String? url,
    String? source,
    bool? isSelected,
    String? providerId,
    int? fileSize,
    String? mimeType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Avatar(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      url: url ?? this.url,
      source: source ?? this.source,
      isSelected: isSelected ?? this.isSelected,
      providerId: providerId ?? this.providerId,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Returns a display-friendly provider name based on providerId
  String get providerName {
    if (providerId == null) return '';
    if (providerId!.startsWith('google_')) return 'Google';
    if (providerId!.startsWith('spotify_')) return 'Spotify';
    return '';
  }

  /// Returns true if this is a provider avatar (Google/Spotify)
  bool get isProviderAvatar => source == 'provider';

  /// Returns true if this is an uploaded avatar
  bool get isUploadedAvatar => source == 'upload';

  /// Returns true if this is the default avatar
  bool get isDefaultAvatar => source == 'default';
}
