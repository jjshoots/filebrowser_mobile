import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';

/// Thin wrapper over the File Browser HTTP API.
///
/// Auth model: `POST /api/login` returns a JWT as a *plain-text* body. That
/// token is sent on every request via the `X-Auth` header. The server sets the
/// `X-Renew-Token: true` response header when the token is close to expiry; we
/// transparently call `/api/renew` when we see it.
class FileBrowserClient {
  FileBrowserClient({required String baseUrl})
      : _baseUrl = _normalizeBase(baseUrl),
        _dio = Dio() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.headers.value('X-Renew-Token') == 'true') {
            _renewPending = true;
          }
          handler.next(response);
        },
      ),
    );
  }

  final Dio _dio;
  final String _baseUrl;

  String? _token;
  bool _renewPending = false;

  /// Called whenever the token changes (initial adoption or renewal) so the
  /// caller can persist it. Captcha-protected servers can't silently re-login,
  /// so keeping the cached JWT fresh via renew matters.
  void Function(String token)? onTokenChanged;

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

  /// Exchanges the current token for a fresh one. No-op if not logged in.
  Future<void> renewIfNeeded() async {
    if (_token == null || !_renewPending) return;
    final resp = await _dio.postUri(
      _endpoint('renew'),
      options: _authOptions(responseType: ResponseType.plain),
    );
    _token = (resp.data as String).trim();
    _renewPending = false;
    onTokenChanged?.call(_token!);
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

  /// Rename/move [fromPath] to [toPath] (both server-relative).
  Future<void> rename(String fromPath, String toPath) async {
    await renewIfNeeded();
    final dst = toPath.split('/').map(Uri.encodeComponent).join('/');
    final uri = _api('resources', fromPath).replace(queryParameters: {
      'action': 'rename',
      'destination': dst.startsWith('/') ? dst : '/$dst',
    });
    await _dio.patchUri(uri, options: _authOptions());
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
