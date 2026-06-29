// Data models mirroring File Browser's `/api/resources` responses.

/// Sort dimensions, mirroring the File Browser web UI's column sorts.
enum SortKey { name, size, modified }

/// Human-readable byte size, e.g. `512 B`, `1.5 KB`, `2.0 GB`.
///
/// Single source of truth shared by the UI and the disk-usage models; mirrors
/// the File Browser web UI's binary (1024) units with one decimal place.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double size = bytes / 1024;
  int i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(1)} ${units[i]}';
}

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

  /// [modified] parsed as a `DateTime` (UTC), or null when absent/unparseable.
  /// The server emits RFC3339/ISO-8601 timestamps.
  DateTime? get modifiedAt {
    final m = modified;
    if (m == null || m.isEmpty) return null;
    return DateTime.tryParse(m);
  }

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

/// A single hit from `GET /api/search/<path>?query=...`.
///
/// The search endpoint streams newline-delimited JSON objects of the shape
/// `{"dir": bool, "path": string}` (see the client's `search()` for parsing);
/// [path] is relative to the searched directory.
class FbSearchResult {
  FbSearchResult({required this.path, required this.isDir});

  /// Path relative to the searched root, e.g. `photos/img.jpg`.
  final String path;
  final bool isDir;

  /// The last path segment (the file/folder name), trailing slash ignored.
  String get name {
    final trimmed =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final slash = trimmed.lastIndexOf('/');
    return slash == -1 ? trimmed : trimmed.substring(slash + 1);
  }

  factory FbSearchResult.fromJson(Map<String, dynamic> json) => FbSearchResult(
        path: (json['path'] ?? '') as String,
        isDir: (json['dir'] ?? false) as bool,
      );
}

/// Disk usage for a path, from `GET /api/usage/<path>` -> `{total, used}`.
///
/// Both values are byte counts. The server reports `0/0` for non-directories.
class FbUsage {
  FbUsage({required this.total, required this.used});

  /// Total capacity of the filesystem backing the path, in bytes.
  final int total;

  /// Used space on that filesystem, in bytes.
  final int used;

  /// Fraction of capacity used in `0.0..1.0` (0 when [total] is 0).
  double get usedFraction => total == 0 ? 0 : used / total;

  /// Free space in bytes (never negative).
  int get free => (total - used) < 0 ? 0 : total - used;

  String get usedHuman => formatBytes(used);
  String get totalHuman => formatBytes(total);
  String get freeHuman => formatBytes(free);

  factory FbUsage.fromJson(Map<String, dynamic> json) => FbUsage(
        total: (json['total'] as num?)?.toInt() ?? 0,
        used: (json['used'] as num?)?.toInt() ?? 0,
      );
}

/// A share link, from the `/api/share*` endpoints.
///
/// The server deliberately never returns the bcrypt password hash; it exposes
/// only [hasPassword]. [token] (a URL-safe bypass token for password-protected
/// downloads) is NOT emitted by this server version on any endpoint — the
/// share-creation response renders only `{hash, path, userID, expire,
/// hasPassword}`. The field is kept nullable for forward-compatibility but is
/// always null in practice against this server.
class FbShare {
  FbShare({
    required this.hash,
    required this.path,
    required this.expire,
    required this.hasPassword,
    this.userID,
    this.token,
  });

  /// Short random id used to build the public share URL (`/share/<hash>`).
  final String hash;

  /// Server-relative path that is shared.
  final String path;

  /// Unix expiry time in seconds; `0` means the share never expires.
  final int expire;

  final bool hasPassword;
  final int? userID;

  /// Bypass token for password-protected shares. Not emitted by this server
  /// version, so always null in practice; kept for forward-compatibility.
  final String? token;

  /// Whether the share has a finite expiry that is already in the past.
  bool get isExpired =>
      expire != 0 && expire <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Expiry as a `DateTime` (local), or null when the share never expires.
  DateTime? get expiresAt => expire == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expire * 1000);

  factory FbShare.fromJson(Map<String, dynamic> json) => FbShare(
        hash: (json['hash'] ?? '') as String,
        path: (json['path'] ?? '') as String,
        expire: (json['expire'] as num?)?.toInt() ?? 0,
        hasPassword: (json['hasPassword'] ?? false) as bool,
        userID: (json['userID'] as num?)?.toInt(),
        token: json['token'] as String?,
      );
}

/// tus.io chunked-upload parameters advertised by the server settings.
///
/// M5 (resumable uploads) will use these to size each PATCH chunk and bound the
/// per-chunk retry budget. Defaults mirror the server's
/// `DefaultTusChunkSize` (10 MiB) / `DefaultTusRetryCount` (5).
class FbTusConfig {
  const FbTusConfig({this.chunkSize = 10 * 1024 * 1024, this.retryCount = 5});

  /// Bytes per upload chunk (PATCH body size).
  final int chunkSize;

  /// Number of retries per chunk before giving up.
  final int retryCount;

  factory FbTusConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const FbTusConfig();
    final cs = (json['chunkSize'] as num?)?.toInt();
    final rc = (json['retryCount'] as num?)?.toInt();
    return FbTusConfig(
      chunkSize: (cs == null || cs <= 0) ? 10 * 1024 * 1024 : cs,
      retryCount: (rc == null || rc < 0) ? 5 : rc,
    );
  }
}

/// Server capabilities/branding, from `GET /api/settings` (admin-only).
///
/// Only the fields a mobile client needs are modelled; the full settings
/// payload (rules, user defaults, commands, …) is ignored.
class FbServerCaps {
  FbServerCaps({
    required this.signup,
    required this.createUserDir,
    required this.name,
    required this.tus,
  });

  /// Whether self-service signup is enabled.
  final bool signup;

  /// Whether new users get their own home directory.
  final bool createUserDir;

  /// Branding name shown in the UI (empty when unset).
  final String name;

  final FbTusConfig tus;

  factory FbServerCaps.fromJson(Map<String, dynamic> json) {
    final branding = json['branding'] as Map<String, dynamic>?;
    return FbServerCaps(
      signup: (json['signup'] ?? false) as bool,
      createUserDir: (json['createUserDir'] ?? false) as bool,
      name: (branding?['name'] ?? '') as String,
      tus: FbTusConfig.fromJson(json['tus'] as Map<String, dynamic>?),
    );
  }
}
