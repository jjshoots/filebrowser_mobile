// Data models mirroring File Browser's `/api/resources` responses.

/// Sort dimensions, mirroring the File Browser web UI's column sorts.
enum SortKey { name, size, modified }

/// How tapping a resource activates it in the browser: navigate into a folder,
/// open the in-app image/video viewer, or hand a non-media file off to a native
/// Android app via open-with. Kept widget-free so the routing decision is pure
/// and unit-testable (see [FbResource.activation]).
enum ResourceActivation { openFolder, viewImage, playVideo, openExternally }

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
    final type = json['type'] as String?;
    final path = (json['path'] ?? '') as String;
    // A directory listing carries its children split into `folders` + `files`;
    // a leaf resource carries neither. `isDir` follows the `type` field, falling
    // back to a bare `isDir` flag when one is present.
    final isDir = type == 'directory' || (json['isDir'] ?? false) as bool;

    final folders = json['folders'];
    final files = json['files'];
    final List<FbResource> items;
    if (folders is List || files is List) {
      // Merge folders then files into one list (folders first, matching the web
      // client) and compute each child's path from this directory's path, since
      // children are returned without one.
      final merged = <FbResource>[];
      for (final raw in [
        if (folders is List) ...folders,
        if (files is List) ...files,
      ]) {
        if (raw is Map<String, dynamic>) {
          merged.add(FbResource.fromJson(_withChildPath(raw, path)));
        }
      }
      items = merged;
    } else {
      final rawItems = json['items'];
      items = rawItems is List
          ? rawItems
              .whereType<Map<String, dynamic>>()
              .map(FbResource.fromJson)
              .toList()
          : const [];
    }

    return FbResource(
      path: path,
      name: (json['name'] ?? '') as String,
      size: (json['size'] as num?)?.toInt() ?? 0,
      isDir: isDir,
      modified: json['modified'] as String?,
      type: type,
      extension: json['extension'] as String?,
      items: items,
    );
  }

  /// Returns [child] with a computed `path` derived from [parentPath]: the
  /// parent path joined with the child's name, plus a trailing slash for
  /// directories. A pre-existing `path` is left untouched.
  static Map<String, dynamic> _withChildPath(
      Map<String, dynamic> child, String parentPath) {
    final existing = child['path'];
    if (existing is String && existing.isNotEmpty) return child;
    final name = (child['name'] ?? '') as String;
    final childIsDir = child['type'] == 'directory';
    final parent =
        parentPath.isEmpty || parentPath.endsWith('/') ? parentPath : '$parentPath/';
    final base = parent.isEmpty ? '/$name' : '$parent$name';
    return {...child, 'path': childIsDir ? '$base/' : base};
  }

  static const _imageExts = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'tif', 'tiff', 'svg'
  };
  static const _videoExts = {
    'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v', '3gp', 'flv', 'wmv', 'mpeg', 'mpg'
  };
  static const _audioExts = {
    'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'oga', 'opus', 'wma', 'aiff', 'alac'
  };
  static const _pdfExts = {'pdf'};
  static const _textExts = {
    'txt', 'md', 'markdown', 'log', 'json', 'yaml', 'yml', 'xml', 'csv', 'ini',
    'conf', 'sh', 'dart', 'js', 'ts', 'html', 'htm', 'css', 'c', 'h', 'cpp',
    'java', 'kt', 'py', 'go', 'rs', 'toml', 'rtf'
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
  bool get isAudio => !isDir && (_audioExts.contains(_ext) || type == 'audio');
  bool get isPdf => !isDir && (_pdfExts.contains(_ext) || type == 'pdf');
  bool get isText =>
      !isDir &&
      (_textExts.contains(_ext) || type == 'text' || type == 'textImmutable');
  bool get isViewableMedia => isImage || isVideo;

  /// How the browser should activate this resource when tapped. Media opens the
  /// in-app viewer/player; every other file (pdf/text/audio and unknown types)
  /// is handed to a native app via open-with. Mirrors [_handleTap]'s routing so
  /// the decision can be unit-tested without the widget tree.
  ResourceActivation get activation {
    if (isDir) return ResourceActivation.openFolder;
    if (isImage) return ResourceActivation.viewImage;
    if (isVideo) return ResourceActivation.playVideo;
    return ResourceActivation.openExternally;
  }

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

/// Minimal view of the authenticated user.
///
/// The session JWT carries permissions but not the username (its payload holds
/// a `Permissions` object and the user id under `belongsTo`), so the username is
/// supplied separately from the login form.
class FbUser {
  FbUser({required this.username, required this.canCreate, required this.canModify});

  final String username;
  final bool canCreate;
  final bool canModify;

  /// Builds a user from the decoded JWT [claims]. The session token exposes a
  /// top-level `Permissions` map (`create`/`modify`/…); [username] comes from
  /// the credentials used to log in.
  factory FbUser.fromClaims(Map<String, dynamic> claims, {String username = ''}) {
    final perm = (claims['Permissions'] as Map<String, dynamic>?) ??
        (claims['permissions'] as Map<String, dynamic>?) ??
        const {};
    return FbUser(
      username: username,
      canCreate: (perm['create'] ?? false) as bool,
      canModify: (perm['modify'] ?? false) as bool,
    );
  }
}

/// A single hit from `GET /api/tools/search`.
///
/// Results come back as a plain JSON array of `{path, type, source}` objects.
/// [path] is absolute within the source's user scope (directories carry a
/// trailing slash); [isDir] follows the `type` field.
class FbSearchResult {
  FbSearchResult({required this.path, required this.isDir, this.source});

  /// Source-scoped absolute path, e.g. `/photos/img.jpg`.
  final String path;
  final bool isDir;

  /// Name of the source this hit belongs to (present in multi-source results).
  final String? source;

  /// The last path segment (the file/folder name), trailing slash ignored.
  String get name {
    final trimmed =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final slash = trimmed.lastIndexOf('/');
    return slash == -1 ? trimmed : trimmed.substring(slash + 1);
  }

  factory FbSearchResult.fromJson(Map<String, dynamic> json) => FbSearchResult(
        path: (json['path'] ?? '') as String,
        isDir: json['type'] == 'directory',
        source: json['source'] as String?,
      );
}

/// Disk usage for a source, derived from its entry in
/// `GET /api/settings/sources` (`{used, usedAlt, total}` byte counts).
///
/// `used` is the indexed (logical) size; `usedAlt` is the real disk space the
/// source's filesystem reports as used; `total` is its capacity. The disk gauge
/// binds to [usedAlt] (defaulting to [used] when not reported separately).
class FbUsage {
  FbUsage({required this.total, required this.used, int? usedAlt})
      : usedAlt = usedAlt ?? used;

  /// Total capacity of the filesystem backing the source, in bytes.
  final int total;

  /// Indexed (logical) size, in bytes.
  final int used;

  /// Real disk space used on the backing filesystem, in bytes. The disk gauge
  /// reports this rather than the logical index size.
  final int usedAlt;

  /// Fraction of capacity used in `0.0..1.0` (0 when [total] is 0).
  double get usedFraction => total == 0 ? 0 : usedAlt / total;

  /// Free space in bytes (never negative).
  int get free => (total - usedAlt) < 0 ? 0 : total - usedAlt;

  String get usedHuman => formatBytes(usedAlt);
  String get totalHuman => formatBytes(total);
  String get freeHuman => formatBytes(free);

  factory FbUsage.fromJson(Map<String, dynamic> json) => FbUsage(
        total: (json['total'] as num?)?.toInt() ?? 0,
        used: (json['used'] as num?)?.toInt() ?? 0,
        usedAlt: (json['usedAlt'] as num?)?.toInt(),
      );

  /// Like [fromJson] but returns null when no real capacity is reported (a
  /// source that hasn't been indexed yet, or one without disk stats), so the
  /// UI can degrade rather than render an empty `0 / 0` gauge.
  static FbUsage? fromJsonOrNull(Map<String, dynamic> json) {
    final total = (json['total'] as num?)?.toInt() ?? 0;
    if (total <= 0) return null;
    return FbUsage.fromJson(json);
  }
}

/// A browsable source, from `GET /api/settings/sources`.
///
/// The endpoint returns a map keyed by source name; each value is the source's
/// index summary, carrying its display [name] and, when available, disk
/// [usage]. The backing filesystem path is not exposed by this endpoint.
class FbSource {
  FbSource({required this.name, this.path, this.usage});

  /// Source name — the key used for the `source=` query param on every
  /// path-scoped request.
  final String name;

  /// Backing filesystem path, when known (absent from the sources endpoint).
  final String? path;

  /// Disk usage for the source, or null when none is reported.
  final FbUsage? usage;

  factory FbSource.fromJson(String name, Map<String, dynamic> json) => FbSource(
        name: name,
        path: json['path'] as String?,
        usage: FbUsage.fromJsonOrNull(json),
      );
}

/// A share link, from the `/api/share*` endpoints.
///
/// The server never returns the bcrypt password hash; it exposes only
/// [hasPassword]. [token] (a URL-safe bypass token used to download
/// password-protected shares) is returned only when the share is password
/// protected, so it stays nullable. Extra fields the server may attach
/// (downloadsLimit, shareType, …) are ignored.
class FbShare {
  FbShare({
    required this.hash,
    required this.path,
    required this.expire,
    required this.hasPassword,
    this.source,
    this.username,
    this.userID,
    this.token,
  });

  /// Short random id used to build the public share URL (`/share/<hash>`).
  final String hash;

  /// Source-scoped path that is shared.
  final String path;

  /// Name of the source the shared path lives in.
  final String? source;

  /// Username of the share's creator (populated on listings).
  final String? username;

  /// Unix expiry time in seconds; `0` means the share never expires.
  final int expire;

  final bool hasPassword;
  final int? userID;

  /// Bypass token for downloading a password-protected share; null otherwise.
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
        source: json['source'] as String?,
        username: json['username'] as String?,
        expire: (json['expire'] as num?)?.toInt() ?? 0,
        hasPassword: (json['hasPassword'] ?? false) as bool,
        userID: (json['userID'] as num?)?.toInt(),
        token: json['token'] as String?,
      );
}

/// Chunked-upload parameters used to size each upload chunk and bound the
/// per-chunk retry budget.
///
/// The server advertises no chunk config, so these are local defaults (10 MiB
/// chunks, 5 retries); kept as a model so call sites have a single source.
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
/// The endpoint returns the whole config tree; only the few fields a mobile
/// client needs are modelled. Signup lives under `auth.methods.password`, the
/// branding name under `frontend.name`. Flat keys are also tolerated so a
/// trimmed payload (or a graceful 403 default) still maps.
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
    final auth = json['auth'] as Map<String, dynamic>?;
    final methods = auth?['methods'] as Map<String, dynamic>?;
    final password = methods?['password'] as Map<String, dynamic>?;
    final frontend = json['frontend'] as Map<String, dynamic>?;
    return FbServerCaps(
      signup: (password?['signup'] ?? json['signup'] ?? false) as bool,
      createUserDir: (json['createUserDir'] ?? false) as bool,
      name: (frontend?['name'] ?? json['name'] ?? '') as String,
      tus: FbTusConfig.fromJson(json['tus'] as Map<String, dynamic>?),
    );
  }
}
