import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import 'secure_store.dart';

enum AuthStage {
  /// No stored credentials — show the setup form (server URL + credentials).
  needsSetup,

  /// Credentials exist; waiting for biometric unlock.
  locked,

  /// Unlocked but no valid cached token — show the WebView login so the user
  /// can solve the captcha. Credentials are pre-filled from secure storage.
  needsLogin,

  /// A valid JWT is held; the file browser is usable.
  authenticated,

  /// A biometric/network step is in flight.
  busy,
}

/// Login target passed to the WebView screen (pre-fill + base URL).
class LoginTarget {
  LoginTarget({required this.baseUrl, required this.username, required this.password});
  final String baseUrl;
  final String username;
  final String password;
}

/// Orchestrates: stored credentials -> biometric gate -> cached JWT or
/// WebView captcha login -> authenticated session.
///
/// Because the server uses a captcha, we cannot silently re-login: a fresh
/// token always requires the user to solve the challenge in the WebView. We
/// therefore cache the JWT and keep it alive via renew (which is captcha-free);
/// only when it has truly expired do we route back to [AuthStage.needsLogin].
class AuthController extends ChangeNotifier {
  AuthController({SecureStore? store, LocalAuthentication? localAuth})
      : _store = store ?? SecureStore(),
        _localAuth = localAuth ?? LocalAuthentication();

  final SecureStore _store;
  final LocalAuthentication _localAuth;

  AuthStage _stage = AuthStage.busy;
  AuthStage get stage => _stage;

  String? _error;
  String? get error => _error;

  FileBrowserClient? _client;
  FileBrowserClient? get client => _client;

  FbUser? _user;
  FbUser? get user => _user;

  LoginTarget? _loginTarget;
  LoginTarget? get loginTarget => _loginTarget;

  Future<void> bootstrap() async {
    _setStage(AuthStage.busy);
    _stage =
        (await _store.hasCredentials) ? AuthStage.locked : AuthStage.needsSetup;
    notifyListeners();
  }

  /// First-run: persist the server URL + credentials, then go to the WebView
  /// login so the user can solve the captcha. No silent network login.
  Future<void> beginSetup({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final normalized = FileBrowserClient(baseUrl: baseUrl).baseUrl;
    await _store.save(baseUrl: normalized, username: username, password: password);
    await _store.clearJwt();
    _loginTarget =
        LoginTarget(baseUrl: normalized, username: username, password: password);
    _setStage(AuthStage.needsLogin);
  }

  /// Biometric unlock -> use a still-valid cached JWT, else route to WebView login.
  Future<bool> unlockWithBiometrics() async {
    _setStage(AuthStage.busy);
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (supported) {
        final ok = await _localAuth.authenticate(
          localizedReason: 'Unlock File Browser',
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: false, // allow device PIN/pattern fallback
          ),
        );
        if (!ok) {
          _fail('Biometric authentication was cancelled.', AuthStage.locked);
          return false;
        }
      }
      final creds = await _store.read();
      if (creds == null) {
        _stage = AuthStage.needsSetup;
        notifyListeners();
        return false;
      }

      // Reuse a cached token if it's still valid; otherwise the captcha login.
      final cached = await _store.readJwt();
      if (cached != null && FileBrowserClient.isTokenValid(cached)) {
        _adoptClient(creds.baseUrl, cached);
        _setStage(AuthStage.authenticated);
        return true;
      }

      _loginTarget = LoginTarget(
          baseUrl: creds.baseUrl,
          username: creds.username,
          password: creds.password);
      _setStage(AuthStage.needsLogin);
      return true;
    } catch (e) {
      _fail('Unlock failed: ${_friendly(e)}', AuthStage.locked);
      return false;
    }
  }

  /// Called by the WebView screen once it harvests a JWT from localStorage.
  Future<void> completeWebLogin(String jwt) async {
    final creds = await _store.read();
    final baseUrl = creds?.baseUrl ?? _loginTarget?.baseUrl;
    if (baseUrl == null) {
      _fail('No server configured.', AuthStage.needsSetup);
      return;
    }
    _adoptClient(baseUrl, jwt);
    await _store.saveJwt(jwt);
    _loginTarget = null;
    _setStage(AuthStage.authenticated);
  }

  /// User cancelled the WebView login.
  void cancelWebLogin() {
    _loginTarget = null;
    _setStage(AuthStage.locked);
  }

  Future<void> signOut({bool forget = false}) async {
    if (forget) {
      await _store.clear();
    } else {
      await _store.clearJwt();
    }
    _client = null;
    _user = null;
    _loginTarget = null;
    _stage = forget ? AuthStage.needsSetup : AuthStage.locked;
    notifyListeners();
  }

  /// On-demand session freshness check: renews the cached JWT if the server
  /// asked us to or it is nearing expiry. Call on screen resume and when a
  /// transfer is enqueued. Renewal is captcha-free; a hard failure is routed
  /// to [AuthStage.needsLogin] via [onSessionExpired] (no relock, no loop).
  Future<void> ensureFreshSession() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.ensureFreshSession();
    } on SessionExpiredException {
      // onSessionExpired already routed us to the WebView login.
    } catch (_) {
      // Transient network errors keep the current session; the 401 path will
      // handle a genuinely dead token on the next authenticated request.
    }
  }

  void _adoptClient(String baseUrl, String jwt) {
    final client = FileBrowserClient(baseUrl: baseUrl);
    client.adoptToken(jwt);
    // Persist renewed tokens so the cached JWT stays fresh between launches.
    client.onTokenChanged = (t) => _store.saveJwt(t);
    // A dead session (401 + failed renew) routes back to the captcha login.
    client.onSessionExpired = _handleSessionExpired;
    _client = client;
    _user = FileBrowserClient.userFromToken(jwt);
  }

  /// Routes an irrecoverably expired session back to the WebView login,
  /// rebuilding [loginTarget] from stored credentials exactly like
  /// [unlockWithBiometrics] does. We never relock behind biometrics here.
  Future<void> _handleSessionExpired() async {
    await _store.clearJwt();
    final creds = await _store.read();
    if (creds == null) {
      _stage = AuthStage.needsSetup;
      notifyListeners();
      return;
    }
    _loginTarget = LoginTarget(
      baseUrl: creds.baseUrl,
      username: creds.username,
      password: creds.password,
    );
    _setStage(AuthStage.needsLogin);
  }

  void _setStage(AuthStage s) {
    _stage = s;
    _error = null;
    notifyListeners();
  }

  void _fail(String message, AuthStage fallback) {
    _error = message;
    _stage = _client != null ? AuthStage.authenticated : fallback;
    notifyListeners();
  }

  String _friendly(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}
