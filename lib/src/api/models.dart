// Data models mirroring File Browser's `/api/resources` responses.

/// Sort dimensions, mirroring the File Browser web UI's column sorts.
enum SortKey { name, size, modified }

/// Natural, case-insensitive string comparison: digit runs compare numerically
/// so `img2` < `img10`. Mirrors the server's `maruel/natural` ordering.
int naturalCompare(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0, j = 0;
  bool isDigit(int c) => c >= 0x30 && c <= 0x39;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (isDigit(cx) && isDigit(cy)) {
      var ei = i;
      while (ei < x.length && isDigit(x.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < y.length && isDigit(y.codeUnitAt(ej))) {
        ej++;
      }
      // Strip leading zeros, then compare by length, then lexically.
      final nx = x.substring(i, ei).replaceFirst(RegExp(r'^0+'), '');
      final ny = y.substring(j, ej).replaceFirst(RegExp(r'^0+'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      i = ei;
      j = ej;
    } else {
      if (cx != cy) return cx - cy;
      i++;
      j++;
    }
  }
  return (x.length - i) - (y.length - j);
}

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

  /// Directories first, then natural case-insensitive name order (matches the
  /// File Browser web UI default).
  List<FbResource> get sortedItems => sortedBy(SortKey.name, true);

  /// Returns the items sorted by [key]/[asc]. Folders are always grouped first;
  /// names use natural ordering (so `img2` precedes `img10`) like the web app.
  List<FbResource> sortedBy(SortKey key, bool asc) {
    final list = [...items];
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1; // folders first
      int c;
      switch (key) {
        case SortKey.name:
          c = naturalCompare(a.name, b.name);
          break;
        case SortKey.size:
          c = a.size.compareTo(b.size);
          break;
        case SortKey.modified:
          c = (a.modified ?? '').compareTo(b.modified ?? ''); // ISO8601 sorts lexically
          break;
      }
      if (c == 0) c = naturalCompare(a.name, b.name);
      return asc ? c : -c;
    });
    return list;
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
