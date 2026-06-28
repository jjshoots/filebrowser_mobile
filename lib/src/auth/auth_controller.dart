import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import 'secure_store.dart';

enum AuthStage {
  /// No stored credentials — show the setup/login form.
  needsSetup,

  /// Credentials exist; waiting for biometric unlock.
  locked,

  /// Biometric passed and a fresh JWT was obtained.
  authenticated,

  /// A login/network attempt is in flight.
  busy,
}

/// Orchestrates: stored credentials -> biometric gate -> JWT login.
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

  /// Decide the initial screen based on whether credentials are stored.
  Future<void> bootstrap() async {
    _setStage(AuthStage.busy);
    _stage =
        (await _store.hasCredentials) ? AuthStage.locked : AuthStage.needsSetup;
    notifyListeners();
  }

  /// First-run: validate credentials against the server, then persist them.
  Future<bool> setUpAndLogin({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    _setStage(AuthStage.busy);
    try {
      final client = FileBrowserClient(baseUrl: baseUrl);
      _user = await client.login(username, password);
      _client = client;
      await _store.save(
        baseUrl: client.baseUrl,
        username: username,
        password: password,
      );
      _setStage(AuthStage.authenticated);
      return true;
    } catch (e) {
      _fail('Login failed: ${_friendly(e)}', AuthStage.needsSetup);
      return false;
    }
  }

  /// Biometric unlock -> read stored credentials -> mint a fresh JWT.
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
          _fail('Biometric authentication was cancelled.');
          return false;
        }
      }
      final creds = await _store.read();
      if (creds == null) {
        _stage = AuthStage.needsSetup;
        notifyListeners();
        return false;
      }
      final client = FileBrowserClient(baseUrl: creds.baseUrl);
      _user = await client.login(creds.username, creds.password);
      _client = client;
      _setStage(AuthStage.authenticated);
      return true;
    } catch (e) {
      _fail('Unlock failed: ${_friendly(e)}', AuthStage.locked);
      return false;
    }
  }

  Future<void> signOut({bool forget = false}) async {
    if (forget) await _store.clear();
    _client = null;
    _user = null;
    _stage = forget ? AuthStage.needsSetup : AuthStage.locked;
    notifyListeners();
  }

  void _setStage(AuthStage s) {
    _stage = s;
    _error = null;
    notifyListeners();
  }

  void _fail(String message, AuthStage fallback) {
    _error = message;
    // If we already have a live session, stay in it; otherwise return to the
    // operation-specific entry screen (setup vs. lock).
    _stage = _client != null ? AuthStage.authenticated : fallback;
    notifyListeners();
  }

  String _friendly(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}
