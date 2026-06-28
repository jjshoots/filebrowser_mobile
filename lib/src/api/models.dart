// Data models mirroring File Browser's `/api/resources` responses.

class FbResource {
  FbResource({
    required this.path,
    required this.name,
    required this.size,
    required this.isDir,
    this.modified,
    this.type,
    this.extension,
    this.items = const [],
  });

  /// Server-relative path, e.g. `/photos/img.jpg`.
  final String path;
  final String name;
  final int size;
  final bool isDir;
  final String? modified;
  final String? type;
  final String? extension;

  /// Children, populated only when [isDir] is true and this is a listing.
  final List<FbResource> items;

  factory FbResource.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return FbResource(
      path: (json['path'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      size: (json['size'] ?? 0) as int,
      isDir: (json['isDir'] ?? false) as bool,
      modified: json['modified'] as String?,
      type: json['type'] as String?,
      extension: json['extension'] as String?,
      items: rawItems is List
          ? rawItems
              .whereType<Map<String, dynamic>>()
              .map(FbResource.fromJson)
              .toList()
          : const [],
    );
  }

  static const _imageExts = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'tif', 'tiff', 'svg'
  };
  static const _videoExts = {
    'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v', '3gp', 'flv', 'wmv', 'mpeg', 'mpg'
  };

  String get _ext {
    final fromField = (extension ?? '').replaceAll('.', '').toLowerCase();
    if (fromField.isNotEmpty) return fromField;
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Decided by extension first (reliable in listings), with the server's
  /// `type` field as a fallback hint.
  bool get isImage => !isDir && (_imageExts.contains(_ext) || type == 'image');
  bool get isVideo => !isDir && (_videoExts.contains(_ext) || type == 'video');
  bool get isViewableMedia => isImage || isVideo;

  /// Directories first, then case-insensitive name order — matches the web UI.
  List<FbResource> get sortedItems {
    final sorted = [...items];
    sorted.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }
}

/// Minimal view of the authenticated user (decoded from the login JWT payload).
class FbUser {
  FbUser({required this.username, required this.canCreate, required this.canModify});

  final String username;
  final bool canCreate;
  final bool canModify;

  factory FbUser.fromClaims(Map<String, dynamic> claims) {
    final user = (claims['user'] as Map<String, dynamic>? ) ?? const {};
    final perm = (user['perm'] as Map<String, dynamic>?) ?? const {};
    return FbUser(
      username: (user['username'] ?? '') as String,
      canCreate: (perm['create'] ?? false) as bool,
      canModify: (perm['modify'] ?? false) as bool,
    );
  }
}
