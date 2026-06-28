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
