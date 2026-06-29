import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';

/// Thrown when the session can no longer be refreshed: a 401 was met and a
/// `/api/auth/renew` attempt also failed (or the token is structurally
/// expired).
///
/// The AuthController reacts by re-running the direct login (credentials live in
/// secure storage); it must never trigger a silent retry loop. See
/// [FileBrowserClient]'s 401 interceptor and [FileBrowserClient.onSessionExpired].
class SessionExpiredException implements Exception {
  const SessionExpiredException([this.message = 'Session expired']);
  final String message;
  @override
  String toString() => 'SessionExpiredException: $message';
}

/// Thin wrapper over the filebrowser quantum HTTP API.
///
/// Auth model: `POST /api/auth/login` returns a JWT as a *plain-text* body. That
/// token is sent on every request via `Authorization: Bearer <jwt>`. The server
/// sets the `X-Renew-Token: true` response header when the token is close to
/// expiry; we transparently call `/api/auth/renew` when we see it.
///
/// Quantum is multi-source: every path-scoped call carries a `source` query
/// param. The client holds the [source] selected by the UI and injects it, so
/// call sites pass only paths.
class FileBrowserClient {
  FileBrowserClient({required String baseUrl, HttpClientAdapter? adapter})
      : _baseUrl = _normalizeBase(baseUrl),
        _dio = Dio() {
    if (adapter != null) _dio.httpClientAdapter = adapter;
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.headers.value('X-Renew-Token') == 'true') {
            _renewPending = true;
          }
          handler.next(response);
        },
        onError: _onError,
      ),
    );
  }

  final Dio _dio;
  final String _baseUrl;

  // Marks the internal `/api/auth/renew` call so a 401 on renew itself is NOT
  // retried (which would loop) — it surfaces as a SessionExpiredException.
  static const _kRenewMarker = '__fb_renew__';
  // Marks a request that has already been retried once after a renew, so the
  // 401 interceptor attempts at most one renew+retry per request.
  static const _kRetriedMarker = '__fb_retried__';

  String? _token;
  String? _source;
  bool _renewPending = false;

  /// Called whenever the token changes (initial adoption or renewal) so the
  /// caller can persist it.
  void Function(String token)? onTokenChanged;

  /// Invoked when the session is irrecoverably expired (renew failed on a 401).
  void Function()? onSessionExpired;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  bool get isAuthenticated => _token != null;

  /// Name of the currently selected source, injected into every path-scoped
  /// request. Null until the UI selects one after login.
  String? get source => _source;

  /// Selects the current source (see [source]).
  void setSource(String name) => _source = name;

  /// Adopt a JWT obtained out-of-band (e.g. restored from secure storage).
  void adoptToken(String token) {
    _token = token.trim();
    _renewPending = false;
  }

  /// Decode the permissions claim from a JWT. The username is not carried in the
  /// token, so it is left blank here (the login flow knows it).
  static FbUser userFromToken(String jwt) => _decodeUser(jwt);

  /// Whether [jwt] is well-formed and not within [margin] of expiring.
  static bool isTokenValid(String jwt,
      {Duration margin = const Duration(minutes: 1)}) {
    final exp = _tokenExpiry(jwt);
    if (exp == null) return false;
    return exp.isAfter(DateTime.now().add(margin));
  }

  static String _normalizeBase(String url) {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// Builds `<base>/api/<segment>` (no trailing slash).
  Uri _endpoint(String segment) => Uri.parse('$_baseUrl/api/$segment');

  /// Builds `<base>/api/<segment>?source=<S>&...`. The current [source] is
  /// always injected first; [extra] adds the call-specific params (path, etc.).
  Uri _scopedUri(String segment, [Map<String, dynamic>? extra]) {
    final qp = <String, dynamic>{};
    final s = _source;
    if (s != null && s.isNotEmpty) qp['source'] = s;
    if (extra != null) qp.addAll(extra);
    return _endpoint(segment).replace(queryParameters: qp);
  }

  /// Joins a directory path and a child name with a single separator.
  static String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  Map<String, String>? _bearer() =>
      _token == null ? null : {'Authorization': 'Bearer $_token'};

  Options _authOptions({ResponseType? responseType}) => Options(
        headers: _bearer(),
        responseType: responseType,
      );

  /// Authenticates and stores the JWT in memory. Returns the decoded user.
  ///
  /// Quantum takes the username via query and the password (URL-encoded) and
  /// optional TOTP code via the `X-Password`/`X-Secret` headers; the JWT comes
  /// back as a plain-text body.
  Future<FbUser> login(String username, String password, {String otp = ''}) async {
    final resp = await _dio.postUri(
      _endpoint('auth/login')
          .replace(queryParameters: {'username': username, 'recaptcha': ''}),
      options: Options(
        headers: {
          'X-Password': Uri.encodeComponent(password),
          'X-Secret': otp,
        },
        responseType: ResponseType.plain,
      ),
    );
    _token = (resp.data as String).trim();
    _renewPending = false;
    return _decodeUser(_token!, username: username);
  }

  /// Soft renew: only when the server flagged `X-Renew-Token: true`. No-op if
  /// not logged in or nothing pending. Used opportunistically before requests.
  Future<void> renewIfNeeded() async {
    if (_token == null || !_renewPending) return;
    await _renewToken();
  }

  /// On-demand freshness check (call on screen resume / before a transfer).
  ///
  /// Renews when the server asked us to, or when the cached token is within
  /// [margin] of expiry — staying ahead of the 401 path. Throws
  /// [SessionExpiredException] and fires [onSessionExpired] if the token cannot
  /// be refreshed.
  Future<void> ensureFreshSession({
    Duration margin = const Duration(minutes: 5),
  }) async {
    final token = _token;
    if (token == null) return;
    if (!_renewPending && isTokenValid(token, margin: margin)) return;
    try {
      await _renewToken();
    } on DioException {
      _notifySessionExpired();
      throw const SessionExpiredException();
    }
  }

  /// Exchanges the current token for a fresh one via `/api/auth/renew`. The
  /// request is marked so the 401 interceptor leaves it alone (no retry loop).
  Future<void> _renewToken() async {
    final resp = await _dio.postUri(
      _endpoint('auth/renew'),
      options: Options(
        headers: _bearer(),
        responseType: ResponseType.plain,
        extra: const {_kRenewMarker: true},
      ),
    );
    _token = (resp.data as String).trim();
    _renewPending = false;
    onTokenChanged?.call(_token!);
  }

  void _notifySessionExpired() {
    _renewPending = false;
    onSessionExpired?.call();
  }

  /// 401 handler: on an authenticated request, attempt ONE `/api/auth/renew`
  /// then replay the original request with the fresh token. If renew fails (or
  /// the request is itself the renew call), surface [SessionExpiredException]
  /// and fire [onSessionExpired]. Non-401 errors pass straight through.
  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final req = err.requestOptions;
    final is401 = err.response?.statusCode == 401;
    final wasAuthenticated = req.headers.containsKey('Authorization');
    final isRenew = req.extra[_kRenewMarker] == true;
    final alreadyRetried = req.extra[_kRetriedMarker] == true;

    if (!is401 || !wasAuthenticated || isRenew || alreadyRetried ||
        _token == null) {
      handler.next(err);
      return;
    }

    try {
      await _renewToken();
    } catch (_) {
      _notifySessionExpired();
      handler.reject(
        DioException(
          requestOptions: req,
          response: err.response,
          type: DioExceptionType.badResponse,
          error: const SessionExpiredException(),
        ),
      );
      return;
    }

    // Replay the original request once with the refreshed token.
    req.extra[_kRetriedMarker] = true;
    req.headers['Authorization'] = 'Bearer $_token';
    try {
      final replayed = await _dio.fetch<dynamic>(req);
      handler.resolve(replayed);
    } on DioException catch (e) {
      handler.reject(e);
    }
  }

  /// Lists a directory. [path] is source-relative (`/` is the source root).
  Future<FbResource> listDirectory(String path) async {
    await renewIfNeeded();
    final resp = await _dio.getUri(
      _scopedUri('resources', {'path': path}),
      options: _authOptions(),
    );
    final data = resp.data;
    final map = data is String ? jsonDecode(data) : data;
    return FbResource.fromJson(map as Map<String, dynamic>);
  }

  /// Lightweight remote-existence probe (e.g. for upload conflict detection).
  ///
  /// Issues `GET /api/resources?path=&source=`: 200 means the path exists, 404
  /// means it does not. Other statuses propagate as [DioException].
  Future<bool> resourceExists(String path) async {
    await renewIfNeeded();
    try {
      await _dio.getUri(_scopedUri('resources', {'path': path}),
          options: _authOptions());
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return false;
      rethrow;
    }
  }

  /// Checksum of [path] using [algo] (`md5`/`sha1`/`sha256`/`sha512`).
  ///
  /// The resources endpoint returns the file metadata with a `checksums` map
  /// when asked for one; we return the hex digest for [algo].
  Future<String> checksum(String path, {String algo = 'sha256'}) async {
    await renewIfNeeded();
    final resp = await _dio.getUri(
      _scopedUri('resources', {'path': path, 'checksum': algo}),
      options: _authOptions(),
    );
    final map = _asMap(resp.data);
    final sums = map['checksums'];
    if (sums is Map && sums[algo] is String) return sums[algo] as String;
    return '';
  }

  /// Raw file URL for in-app viewing/streaming. [inline] sets inline
  /// disposition. Requires [authHeaders].
  Uri rawUri(String path, {bool inline = false}) => _scopedUri(
        'resources/download',
        {'file': path, if (inline) 'inline': 'true'},
      );

  /// Direct download URL for [path] (a single file, or a bundle with `algo`).
  /// The caller hands this to the background downloader with [authHeaders].
  Uri rawDownloadUri(String path, {String? algo}) => _scopedUri(
        'resources/download',
        {'file': path, if (algo != null) 'algo': algo},
      );

  /// Archive download URL for several entries that live directly inside
  /// [dirPath]: each `file` param is the full source-scoped path
  /// (`join(dirPath, name)`), repeated, with `algo` (zip/tar.gz).
  Uri rawBundleDownloadUri(String dirPath, List<String> names,
      {String algo = 'zip'}) {
    final files = names.map((n) => _join(dirPath, n)).toList();
    return _scopedUri('resources/download', {'file': files, 'algo': algo});
  }

  /// Thumbnail/preview URL. [size] is 'small', 'large' or 'original'. Requires
  /// [authHeaders].
  Uri previewUri(String path, {String size = 'small'}) => _scopedUri(
        'resources/preview',
        {'path': path, 'size': size, 'inline': 'true'},
      );

  /// Upload target URL: `POST` here with the file's raw bytes as the body.
  /// The server replies 409 Conflict when the path exists and [override] is
  /// false.
  Uri uploadUri(String path, {bool override = true}) => _scopedUri(
        'resources',
        {'path': path, 'override': override.toString()},
      );

  /// Headers for image/video loaders (CachedNetworkImage, VideoPlayer, …) and
  /// the background downloader.
  Map<String, String> get authHeaders =>
      _token == null ? const {} : {'Authorization': 'Bearer $_token'};

  /// Creates a directory (`POST /api/resources?path=&source=&isDir=true`).
  Future<void> makeDirectory(String path) async {
    await renewIfNeeded();
    await _dio.postUri(
      _scopedUri('resources', {'path': path, 'isDir': 'true'}),
      options: _authOptions(),
    );
  }

  Future<void> delete(String path) async {
    await renewIfNeeded();
    await _dio.deleteUri(
      _scopedUri('resources', {'path': path}),
      options: _authOptions(),
    );
  }

  /// Move/copy/rename body for [src] -> [dst] within the current source.
  ///
  /// `rename:true` (our "keep both") makes the server auto-version a conflicting
  /// destination; `overwrite:true` overwrites. Same-dir rename uses
  /// `action:rename`, cross-dir move uses `action:move`, copy uses `action:copy`.
  Future<void> _patch(
    String action,
    String src,
    String dst, {
    required bool overwrite,
    required bool keepBoth,
  }) async {
    await renewIfNeeded();
    final s = _source;
    await _dio.patchUri(
      _endpoint('resources'),
      data: jsonEncode({
        'action': action,
        'items': [
          {'fromSource': s, 'fromPath': src, 'toSource': s, 'toPath': dst},
        ],
        'overwrite': overwrite,
        'rename': keepBoth,
      }),
      options: Options(headers: _bearer(), contentType: Headers.jsonContentType),
    );
  }

  /// Cross-directory move of [src] to [dst] (`action:move`).
  Future<void> move(String src, String dst,
          {bool overwrite = false, bool keepBoth = false}) =>
      _patch('move', src, dst, overwrite: overwrite, keepBoth: keepBoth);

  /// Copy [src] to [dst] (`action:copy`).
  Future<void> copy(String src, String dst,
          {bool overwrite = false, bool keepBoth = false}) =>
      _patch('copy', src, dst, overwrite: overwrite, keepBoth: keepBoth);

  /// Rename [from] to [to] within the same parent directory (`action:rename`).
  Future<void> rename(String from, String to) =>
      _patch('rename', from, to, overwrite: false, keepBoth: false);

  /// Full-text search under [scope] for [query] in the current source.
  ///
  /// Hits `GET /api/tools/search?query=&sources=<S>&scope=<base/>`. Results are
  /// a plain JSON array; each `path` is absolute within the source's user scope.
  Future<List<FbSearchResult>> search(String scope, String query) async {
    await renewIfNeeded();
    var base = scope.endsWith('/') ? scope : '$scope/';
    final qp = <String, dynamic>{
      'query': query,
      if (_source != null) 'sources': _source,
      'scope': base,
    };
    final resp = await _dio.getUri(
      _endpoint('tools/search').replace(queryParameters: qp),
      options: _authOptions(),
    );
    final data = resp.data is String ? jsonDecode(resp.data as String) : resp.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((m) => FbSearchResult.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Discovers the available sources (`GET /api/settings/sources`), keyed by
  /// source name. Each entry carries the source's disk usage when reported.
  Future<Map<String, FbSource>> listSources() async {
    await renewIfNeeded();
    final resp = await _dio.getUri(
      _endpoint('settings/sources'),
      options: _authOptions(),
    );
    final map = _asMap(resp.data);
    final out = <String, FbSource>{};
    map.forEach((name, value) {
      if (value is Map) {
        out[name] = FbSource.fromJson(name, value.cast<String, dynamic>());
      }
    });
    return out;
  }

  /// Disk usage for the current source, derived from [listSources]. Null when no
  /// usage is available (source unindexed or unknown).
  Future<FbUsage?> diskUsage() async {
    final sources = await listSources();
    final s = _source;
    final src = (s != null ? sources[s] : null) ??
        (sources.length == 1 ? sources.values.first : null);
    return src?.usage;
  }

  /// All shares visible to the user (`GET /api/share/list`).
  Future<List<FbShare>> listShares() async {
    await renewIfNeeded();
    final resp =
        await _dio.getUri(_endpoint('share/list'), options: _authOptions());
    return _asShareList(resp.data);
  }

  /// Create a share for [path] in the current source (`POST /api/share`).
  ///
  /// [expires] is a count and [unit] its granularity (`seconds`/`minutes`/
  /// `hours`/`days`). The response carries the new share, including a [token]
  /// for password-protected shares.
  Future<FbShare> createShare(
    String path, {
    String? password,
    String? expires,
    String? unit,
  }) async {
    await renewIfNeeded();
    final resp = await _dio.postUri(
      _endpoint('share'),
      data: jsonEncode({
        'path': path,
        if (_source != null) 'source': _source,
        'password': password ?? '',
        'expires': expires ?? '',
        'unit': unit ?? '',
      }),
      options: Options(headers: _bearer(), contentType: Headers.jsonContentType),
    );
    return FbShare.fromJson(_asMap(resp.data));
  }

  /// Delete the share identified by [hash] (`DELETE /api/share?hash=<hash>`).
  Future<void> deleteShare(String hash) async {
    await renewIfNeeded();
    await _dio.deleteUri(
      _endpoint('share').replace(queryParameters: {'hash': hash}),
      options: _authOptions(),
    );
  }

  /// Server capabilities/branding (`GET /api/settings`, admin-only). Returns
  /// permissive defaults when the server forbids the call (non-admin user).
  Future<FbServerCaps> getSettings() async {
    await renewIfNeeded();
    try {
      final resp = await _dio.getUri(
        _endpoint('settings').replace(queryParameters: {'property': ''}),
        options: _authOptions(),
      );
      return FbServerCaps.fromJson(_asMap(resp.data));
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        return FbServerCaps(
          signup: false,
          createUserDir: false,
          name: '',
        );
      }
      rethrow;
    }
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    final decoded = data is String ? jsonDecode(data) : data;
    return (decoded as Map).cast<String, dynamic>();
  }

  static List<FbShare> _asShareList(dynamic data) {
    final decoded = data is String ? jsonDecode(data) : data;
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((m) => FbShare.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  static FbUser _decodeUser(String jwt, {String username = ''}) {
    final parts = jwt.split('.');
    if (parts.length != 3) {
      return FbUser(username: username, canCreate: false, canModify: false);
    }
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    return FbUser.fromClaims(
      jsonDecode(payload) as Map<String, dynamic>,
      username: username,
    );
  }

  static DateTime? _tokenExpiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
              as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt());
    } catch (_) {
      return null;
    }
  }
}
