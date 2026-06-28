import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the server URL and login credentials in platform-backed secure
/// storage. On Android this is backed by the Keystore + EncryptedSharedPreferences.
///
/// We store the long-lived *credentials* (not the short-lived 2h JWT) so that a
/// biometric unlock can always mint a fresh token via `/api/login`.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _kBaseUrl = 'fb_base_url';
  static const _kUsername = 'fb_username';
  static const _kPassword = 'fb_password';
  static const _kJwt = 'fb_jwt';

  Future<bool> get hasCredentials async {
    final values = await _storage.readAll();
    return values.containsKey(_kBaseUrl) &&
        values.containsKey(_kUsername) &&
        values.containsKey(_kPassword);
  }

  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    await _storage.write(key: _kBaseUrl, value: baseUrl);
    await _storage.write(key: _kUsername, value: username);
    await _storage.write(key: _kPassword, value: password);
  }

  Future<({String baseUrl, String username, String password})?> read() async {
    final baseUrl = await _storage.read(key: _kBaseUrl);
    final username = await _storage.read(key: _kUsername);
    final password = await _storage.read(key: _kPassword);
    if (baseUrl == null || username == null || password == null) return null;
    return (baseUrl: baseUrl, username: username, password: password);
  }

  /// The cached JWT (kept fresh via renew). Null until a login succeeds.
  Future<void> saveJwt(String jwt) => _storage.write(key: _kJwt, value: jwt);
  Future<String?> readJwt() => _storage.read(key: _kJwt);
  Future<void> clearJwt() => _storage.delete(key: _kJwt);

  Future<void> clear() => _storage.deleteAll();
}
