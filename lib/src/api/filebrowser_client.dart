import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';

/// Thrown when the session can no longer be refreshed: a 401 was met and a
/// `/api/renew` attempt also failed (or the token is structurally expired).
///
/// The UI/AuthController reacts by routing back to the captcha WebView login;
/// it must never trigger a silent retry loop. See [FileBrowserClient]'s 401
/// interceptor and [FileBrowserClient.onSessionExpired].
class SessionExpiredException implements Exception {
  const SessionExpiredException([this.message = 'Session expired']);
  final String message;
  @override
  String toString() => 'SessionExpiredException: $message';
}

/// Thin wrapper over the File Browser HTTP API.
///
/// Auth model: `POST /api/login` returns a JWT as a *plain-text* body. That
/// token is sent on every request via the `X-Auth` header. The server sets the
/// `X-Renew-Token: true` response header when the token is close to expiry; we
/// transparently call `/api/renew` when we see it.
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

  // Marks the internal `/api/renew` call so a 401 on renew itself is NOT
  // retried (which would loop) — it surfaces as a SessionExpiredException.
  static const _kRenewMarker = '__fb_renew__';
  // Marks a request that has already been retried once after a renew, so the
  // 401 interceptor attempts at most one renew+retry per request.
  static const _kRetriedMarker = '__fb_retried__';

  String? _token;
  bool _renewPending = false;

  /// Called whenever the token changes (initial adoption or renewal) so the
  /// caller can persist it. Captcha-protected servers can't silently re-login,
  /// so keeping the cached JWT fresh via renew matters.
  void Function(String token)? onTokenChanged;

  /// Invoked when the session is irrecoverably expired (renew failed on a 401).
  /// The AuthController wires this to route back to the WebView login.
  void Function()? onSessionExpired;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  bool get isAuthenticated => _token != null;

  /// Adopt a JWT obtained out-of-band (e.g. harvested from the WebView login).
  void adoptToken(String token) {
    _token = token.trim();
    _renewPending = false;
  }

  /// Decode the `user` claim from a JWT (same shape as the login response).
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

  /// Builds `<base>/api/<segment>` exactly (no trailing slash). Used for the
  /// auth endpoints (login/renew/signup), which gorilla/mux serves without a
  /// trailing slash — `/api/login/` 404s.
  Uri _endpoint(String segment) => Uri.parse('$_baseUrl/api/$segment');

  /// Builds `<base>/api/<segment>/<url-encoded path>`.
  Uri _api(String segment, [String path = '/']) {
    final encoded = path
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    final normalized = encoded.startsWith('/') ? encoded : '/$encoded';
    return Uri.parse('$_baseUrl/api/$segment$normalized');
  }

  Options _authOptions({ResponseType? responseType}) => Options(
        headers: _token == null ? null : {'X-Auth': _token},
        responseType: responseType,
      );

  /// Authenticates and stores the JWT in memory. Returns the decoded user.
  Future<FbUser> login(String username, String password) async {
    final resp = await _dio.postUri(
      _endpoint('login'),
      data: jsonEncode({
        'username': username,
        'password': password,
        'recaptcha': '',
      }),
      options: Options(
        contentType: Headers.jsonContentType,
        responseType: ResponseType.plain,
      ),
    );
    _token = (resp.data as String).trim();
    _renewPending = false;
    return _decodeUser(_token!);
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
  /// [margin] of expiry — staying ahead of the 401 path. Renewal is captcha
  /// free (`/api/renew`). Throws [SessionExpiredException] and fires
  /// [onSessionExpired] if the token cannot be refreshed.
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

  /// Exchanges the current token for a fresh one via `/api/renew`. The request
  /// is marked so the 401 interceptor leaves it alone (no retry loop).
  Future<void> _renewToken() async {
    final resp = await _dio.postUri(
      _endpoint('renew'),
      options: Options(
        headers: _token == null ? null : {'X-Auth': _token},
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

  /// 401 handler: on an authenticated request, attempt ONE `/api/renew` then
  /// replay the original request with the fresh token. If renew fails (or the
  /// request is itself the renew call), surface [SessionExpiredException] and
  /// fire [onSessionExpired]. Non-401 errors pass straight through.
  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final req = err.requestOptions;
    final is401 = err.response?.statusCode == 401;
    final wasAuthenticated = req.headers.containsKey('X-Auth');
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
    req.headers['X-Auth'] = _token;
    try {
      final replayed = await _dio.fetch<dynamic>(req);
      handler.resolve(replayed);
    } on DioException catch (e) {
      handler.reject(e);
    }
  }

  /// Lists a directory. [path] is server-relative (`/` is the root scope).
  Future<FbResource> listDirectory(String path) async {
    await renewIfNeeded();
    final resp = await _dio.getUri(
      _api('resources', path),
      options: _authOptions(),
    );
    final data = resp.data;
    final map = data is String ? jsonDecode(data) : data;
    return FbResource.fromJson(map as Map<String, dynamic>);
  }

  /// Direct download URL for [path] (single file, or a bundle with `?algo=zip`).
  /// The caller hands this to the background downloader together with [token].
  Uri rawDownloadUri(String path, {String? algo}) {
    final uri = _api('raw', path);
    return algo == null ? uri : uri.replace(queryParameters: {'algo': algo});
  }

  /// Archive download URL for several entries that live directly inside
  /// [dirPath]: `GET /api/raw/<dir>?files=<a,b,…>&algo=zip`.
  ///
  /// The server reads the `files` value, splits it on commas, then
  /// `url.QueryUnescape`s each name a *second* time (see upstream `raw.go`
  /// `parseQueryFiles`). We therefore pre-encode each [names] entry once and let
  /// the URI serialise the second layer — symmetric with [_patchDestUri]'s
  /// double-encoded `destination`. Each name is a single path segment relative
  /// to [dirPath] (i.e. a child's `name`); folders are zipped recursively.
  Uri rawBundleDownloadUri(String dirPath, List<String> names,
      {String algo = 'zip'}) {
    final files = names.map(Uri.encodeComponent).join(',');
    return _api('raw', dirPath)
        .replace(queryParameters: {'files': files, 'algo': algo});
  }

  /// Upload target URL: `POST` here with the file's raw bytes as the body.
  Uri uploadUri(String path, {bool override = true}) {
    return _api('resources', path)
        .replace(queryParameters: {'override': override.toString()});
  }

  /// Thumbnail/preview URL. [size] is 'thumb' or 'big'. Requires [authHeaders].
  Uri previewUri(String path, {String size = 'thumb'}) =>
      _api('preview/$size', path);

  /// Raw file URL for in-app viewing/streaming. [inline] sets inline disposition.
  Uri rawUri(String path, {bool inline = false}) {
    final uri = _api('raw', path);
    return inline ? uri.replace(queryParameters: {'inline': 'true'}) : uri;
  }

  /// Headers for image/video loaders (CachedNetworkImage, VideoPlayer, …).
  Map<String, String> get authHeaders =>
      _token == null ? const {} : {'X-Auth': _token!};

  /// Builds a `PATCH /api/resources/<src>?action=&destination=&override=` URI.
  ///
  /// The server unescapes `destination` *twice* (once via `r.URL.Query()`, then
  /// again with `url.QueryUnescape`), so we pre-encode each path segment here
  /// and let Dio percent-encode the whole value a second time. Path separators
  /// are preserved so the server reconstructs nested destinations correctly.
  Uri _patchDestUri(String src, String dst, String action, bool overwrite) {
    final encoded = dst.split('/').map(Uri.encodeComponent).join('/');
    return _api('resources', src).replace(queryParameters: {
      'action': action,
      'destination': encoded.startsWith('/') ? encoded : '/$encoded',
      'override': overwrite.toString(),
    });
  }

  /// Rename [fromPath] to [toPath] within the same parent directory.
  /// Thin wrapper over [move] (the server treats both as `action=rename`).
  Future<void> rename(String fromPath, String toPath) =>
      move(fromPath, toPath);

  /// Cross-directory move of [src] to [dst] (`action=rename`). When [overwrite]
  /// is false and [dst] already exists the server responds 409 Conflict.
  Future<void> move(String src, String dst, {bool overwrite = false}) async {
    await renewIfNeeded();
    await _dio.patchUri(
      _patchDestUri(src, dst, 'rename', overwrite),
      options: _authOptions(),
    );
  }

  /// Copy [src] to [dst] (`action=copy`). When [overwrite] is false and [dst]
  /// already exists the server responds 409 Conflict.
  Future<void> copy(String src, String dst, {bool overwrite = false}) async {
    await renewIfNeeded();
    await _dio.patchUri(
      _patchDestUri(src, dst, 'copy', overwrite),
      options: _authOptions(),
    );
  }

  /// Full-text search under [path] for [query].
  ///
  /// The endpoint streams newline-delimited JSON (`{"dir":bool,"path":string}`)
  /// with periodic empty heartbeat lines; we read the whole body and parse each
  /// non-empty line. [path] is the search root; result paths are relative to it.
  Future<List<FbSearchResult>> search(String path, String query) async {
    await renewIfNeeded();
    final uri = _api('search', path).replace(queryParameters: {'query': query});
    final resp = await _dio.getUri(
      uri,
      options: _authOptions(responseType: ResponseType.plain),
    );
    final body = (resp.data as String?) ?? '';
    final out = <FbSearchResult>[];
    for (final line in const LineSplitter().convert(body)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue; // heartbeat
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        out.add(FbSearchResult.fromJson(decoded));
      }
    }
    return out;
  }

  /// Disk usage for [path] (`GET /api/usage/<path>` -> `{total, used}`).
  Future<FbUsage> diskUsage(String path) async {
    await renewIfNeeded();
    final resp = await _dio.getUri(_api('usage', path), options: _authOptions());
    final map = _asMap(resp.data);
    return FbUsage.fromJson(map);
  }

  /// All shares visible to the user (`GET /api/shares`). Admins see every share.
  Future<List<FbShare>> listShares() async {
    await renewIfNeeded();
    final resp = await _dio.getUri(_endpoint('shares'), options: _authOptions());
    return _asShareList(resp.data);
  }

  /// Shares that target [path] specifically (`GET /api/share/<path>`).
  Future<List<FbShare>> getShares(String path) async {
    await renewIfNeeded();
    final resp = await _dio.getUri(_api('share', path), options: _authOptions());
    return _asShareList(resp.data);
  }

  /// Create a share for [path] (`POST /api/share/<path>`).
  ///
  /// [expires] is a count and [unit] its granularity (`seconds`/`minutes`/
  /// `hours`/`days`; the server defaults to hours).
  ///
  /// Note: this server version's share-creation response only renders
  /// `{hash, path, userID, expire, hasPassword}` (see upstream
  /// `share.go` `shareResponse`), so [FbShare.token] is always null here —
  /// even for password-protected shares. Do not rely on obtaining a
  /// password-bypass token from this call.
  Future<FbShare> createShare(
    String path, {
    String? password,
    String? expires,
    String? unit,
  }) async {
    await renewIfNeeded();
    final resp = await _dio.postUri(
      _api('share', path),
      data: jsonEncode({
        'password': password ?? '',
        'expires': expires ?? '',
        'unit': unit ?? '',
      }),
      options: Options(
        headers: _token == null ? null : {'X-Auth': _token},
        contentType: Headers.jsonContentType,
      ),
    );
    return FbShare.fromJson(_asMap(resp.data));
  }

  /// Delete the share identified by [hash] (`DELETE /api/share/<hash>`).
  Future<void> deleteShare(String hash) async {
    await renewIfNeeded();
    await _dio.deleteUri(_api('share', hash), options: _authOptions());
  }

  /// Server capabilities/branding (`GET /api/settings`, admin-only).
  Future<FbServerCaps> getSettings() async {
    await renewIfNeeded();
    final resp =
        await _dio.getUri(_endpoint('settings'), options: _authOptions());
    return FbServerCaps.fromJson(_asMap(resp.data));
  }

  /// Checksum of [path] using [algo] (`md5`/`sha1`/`sha256`/`sha512`).
  ///
  /// File Browser computes checksums via the *resources* endpoint
  /// (`GET /api/resources/<path>?checksum=<algo>`) — there is no `/api/raw`
  /// checksum route — returning the file metadata with a `checksums` map and an
  /// empty body. We return the hex digest for [algo].
  Future<String> checksum(String path, {String algo = 'sha256'}) async {
    await renewIfNeeded();
    final uri =
        _api('resources', path).replace(queryParameters: {'checksum': algo});
    final resp = await _dio.getUri(uri, options: _authOptions());
    final map = _asMap(resp.data);
    final sums = map['checksums'];
    if (sums is Map && sums[algo] is String) return sums[algo] as String;
    return '';
  }

  /// Lightweight remote-existence probe for upload conflict detection.
  ///
  /// Issues `GET /api/resources/<path>`: 200 means the path exists, 404 means
  /// it does not. This is the lightest *correct* check the API allows — there is
  /// no HEAD route on `/api/resources`. For a file the server returns only its
  /// metadata (a directory would return a full listing, so prefer probing the
  /// concrete upload target). Other statuses propagate as [DioException].
  Future<bool> resourceExists(String path) async {
    await renewIfNeeded();
    try {
      await _dio.getUri(_api('resources', path), options: _authOptions());
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return false;
      rethrow;
    }
  }

  /// tus.io upload-creation URL (`POST /api/tus/<path>`); the server replies
  /// with a `Location` header that subsequent HEAD/PATCH chunks target.
  ///
  /// M5 (resumable uploads) will: POST here with `Upload-Length`, read the
  /// `Location`, then PATCH chunks of [FbServerCaps.tus].chunkSize with
  /// `Content-Type: application/offset+octet-stream` + `Upload-Offset`, retrying
  /// up to [FbServerCaps.tus].retryCount per chunk. All requests carry `X-Auth`.
  Uri tusUploadUri(String path, {bool override = true}) {
    return _api('tus', path)
        .replace(queryParameters: {'override': override.toString()});
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

  /// Creates a directory (`POST` with a trailing slash, empty body).
  Future<void> makeDirectory(String path) async {
    await renewIfNeeded();
    final p = path.endsWith('/') ? path : '$path/';
    await _dio.postUri(_api('resources', p), options: _authOptions());
  }

  Future<void> delete(String path) async {
    await renewIfNeeded();
    await _dio.deleteUri(_api('resources', path), options: _authOptions());
  }

  static FbUser _decodeUser(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) {
      return FbUser(username: '', canCreate: false, canModify: false);
    }
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    return FbUser.fromClaims(jsonDecode(payload) as Map<String, dynamic>);
  }

  static DateTime? _tokenExpiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
              as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } catch (_) {
      return null;
    }
  }
}
