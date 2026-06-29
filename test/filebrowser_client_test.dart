import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

/// Build a quantum session JWT with the given expiry (seconds since epoch).
/// The session token carries a top-level `Permissions` object and no username.
String makeJwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch, 'iss': 'FileBrowser Quantum', 'Permissions': {'create': true, 'modify': true}})}.sig';

int get _nowS => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  // A long-lived token so requests are "authenticated" and not auto-renewed.
  final liveToken = makeJwt(_nowS + 3600);

  /// Returns a client whose every request is answered by [handler], with
  /// [liveToken] adopted and source `mydisk` selected.
  (FileBrowserClient, MockAdapter) makeClient(
    ResponseBody Function(RequestOptions) handler, {
    String base = 'https://demo.example.com',
  }) {
    final adapter = MockAdapter(handler);
    final client = FileBrowserClient(baseUrl: base, adapter: adapter)
      ..adoptToken(liveToken)
      ..setSource('mydisk');
    return (client, adapter);
  }

  group('login', () {
    test('posts to /api/auth/login with X-Password/X-Secret headers', () async {
      final (client, adapter) =
          makeClient((_) => MockAdapter.text(makeJwt(_nowS + 3600)));
      final user = await client.login('alice', 'p^ss word', otp: '123456');
      final req = adapter.requests.last;
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/auth/login');
      expect(req.uri.queryParameters['username'], 'alice');
      expect(req.uri.queryParameters['recaptcha'], '');
      // password is URL-encoded into the X-Password header.
      expect(req.headers['X-Password'], Uri.encodeComponent('p^ss word'));
      expect(req.headers['X-Secret'], '123456');
      // username comes from the form (the token carries no username), perms from
      // the JWT's Permissions claim.
      expect(user.username, 'alice');
      expect(user.canCreate, isTrue);
      expect(user.canModify, isTrue);
    });
  });

  group('URL construction', () {
    test('listDirectory carries source + path query params', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json({
            'name': 'd',
            'path': '/d/',
            'type': 'directory',
            'folders': [],
            'files': [],
          }));
      await client.listDirectory('/My Photos/2024');
      final uri = adapter.requests.last.uri;
      expect(adapter.requests.last.method, 'GET');
      expect(uri.path, '/api/resources');
      expect(uri.queryParameters['source'], 'mydisk');
      expect(uri.queryParameters['path'], '/My Photos/2024');
    });

    test('search hits /api/tools/search with sources + scope', () async {
      final (client, adapter) = makeClient(
          (_) => MockAdapter.json([
                {'path': '/a.txt', 'type': 'text', 'source': 'mydisk'},
              ]));
      final hits = await client.search('/My Photos/2024', 'rëport space');
      final uri = adapter.requests.last.uri;
      expect(uri.path, '/api/tools/search');
      expect(uri.queryParameters['query'], 'rëport space');
      expect(uri.queryParameters['sources'], 'mydisk');
      // scope is the base path with a guaranteed trailing slash.
      expect(uri.queryParameters['scope'], '/My Photos/2024/');
      expect(hits.single.path, '/a.txt');
      expect(hits.single.source, 'mydisk');
    });

    test('diskUsage derives the current source usage from /settings/sources',
        () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json({
            'mydisk': {
              'name': 'mydisk',
              'used': 4,
              'usedAlt': 5,
              'total': 10,
            },
            'backup': {'name': 'backup', 'total': 0},
          }));
      final usage = await client.diskUsage();
      expect(adapter.requests.last.uri.toString(),
          'https://demo.example.com/api/settings/sources');
      expect(usage, isNotNull);
      expect(usage!.used, 4);
      expect(usage.total, 10);
    });

    test('listSources keys sources by name and maps usage', () async {
      final (client, _) = makeClient((_) => MockAdapter.json({
            'mydisk': {'name': 'mydisk', 'used': 4, 'total': 10},
            'backup': {'name': 'backup', 'total': 0},
          }));
      final sources = await client.listSources();
      expect(sources.keys, containsAll(['mydisk', 'backup']));
      expect(sources['mydisk']!.usage!.total, 10);
      expect(sources['backup']!.usage, isNull);
    });

    test('listShares hits /api/share/list', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json([]));
      await client.listShares();
      expect(adapter.requests.last.uri.toString(),
          'https://demo.example.com/api/share/list');
    });

    test('createShare POSTs path+source+body to /api/share', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json({
            'hash': 'h',
            'path': '/p',
            'source': 'mydisk',
            'expire': 0,
            'hasPassword': true,
            'token': 'bypass',
          }));
      final share = await client.createShare('/p',
          password: 'secret', expires: '2', unit: 'days');
      final req = adapter.requests.last;
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/share');
      final body = jsonDecode(req.data as String) as Map<String, dynamic>;
      expect(body, {
        'path': '/p',
        'source': 'mydisk',
        'password': 'secret',
        'expires': '2',
        'unit': 'days',
      });
      expect(share.token, 'bypass');
      expect(share.hasPassword, isTrue);
    });

    test('deleteShare hits /api/share?hash=', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.text(''));
      await client.deleteShare('aB_9-x');
      final uri = adapter.requests.last.uri;
      expect(adapter.requests.last.method, 'DELETE');
      expect(uri.path, '/api/share');
      expect(uri.queryParameters['hash'], 'aB_9-x');
    });

    test('getSettings hits /api/settings; 403 degrades to defaults', () async {
      var calls = 0;
      final (client, adapter) = makeClient((_) {
        calls++;
        return calls == 1
            ? MockAdapter.json({
                'frontend': {'name': 'My Files'},
                'auth': {
                  'methods': {
                    'password': {'signup': true},
                  },
                },
              })
            : MockAdapter.json({'message': 'forbidden'}, status: 403);
      });
      final caps = await client.getSettings();
      expect(adapter.requests.last.uri.path, '/api/settings');
      expect(caps.name, 'My Files');
      expect(caps.signup, isTrue);
      // A non-admin 403 degrades rather than throwing.
      final degraded = await client.getSettings();
      expect(degraded.signup, isFalse);
      expect(degraded.name, '');
    });

    test('checksum uses /api/resources?checksum= and reads the digest',
        () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json({
            'path': '/a',
            'checksums': {'sha256': 'deadbeef'},
          }));
      final sum = await client.checksum('/a/b c.bin', algo: 'sha256');
      final uri = adapter.requests.last.uri;
      expect(uri.path, '/api/resources');
      expect(uri.queryParameters['path'], '/a/b c.bin');
      expect(uri.queryParameters['checksum'], 'sha256');
      expect(uri.queryParameters['source'], 'mydisk');
      expect(sum, 'deadbeef');
    });

    test('resourceExists returns true on 200, false on 404', () async {
      var calls = 0;
      final (client, _) = makeClient((_) {
        calls++;
        return calls == 1
            ? MockAdapter.json({'path': '/x'})
            : MockAdapter.json({}, status: 404);
      });
      expect(await client.resourceExists('/x'), isTrue);
      expect(await client.resourceExists('/missing'), isFalse);
    });

    test('makeDirectory POSTs isDir=true with source + path', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.text(''));
      await client.makeDirectory('/new folder');
      final uri = adapter.requests.last.uri;
      expect(adapter.requests.last.method, 'POST');
      expect(uri.path, '/api/resources');
      expect(uri.queryParameters['path'], '/new folder');
      expect(uri.queryParameters['isDir'], 'true');
      expect(uri.queryParameters['source'], 'mydisk');
    });

    test('uploadUri targets /api/resources with override + source', () {
      final (client, _) = makeClient((_) => MockAdapter.text(''));
      final uri = client.uploadUri('/dir/file.bin', override: false);
      expect(uri.path, '/api/resources');
      expect(uri.queryParameters['path'], '/dir/file.bin');
      expect(uri.queryParameters['override'], 'false');
      expect(uri.queryParameters['source'], 'mydisk');
    });

    test('previewUri targets /resources/preview with size + inline', () {
      final (client, _) = makeClient((_) => MockAdapter.text(''));
      final uri = client.previewUri('/p/img.jpg', size: 'large');
      expect(uri.path, '/api/resources/preview');
      expect(uri.queryParameters['path'], '/p/img.jpg');
      expect(uri.queryParameters['size'], 'large');
      expect(uri.queryParameters['inline'], 'true');
      expect(uri.queryParameters['source'], 'mydisk');
    });

    test('rawUri/rawDownloadUri target /resources/download with file param',
        () {
      final (client, _) = makeClient((_) => MockAdapter.text(''));
      final inline = client.rawUri('/p/v.mp4', inline: true);
      expect(inline.path, '/api/resources/download');
      expect(inline.queryParameters['file'], '/p/v.mp4');
      expect(inline.queryParameters['inline'], 'true');
      expect(inline.queryParameters['source'], 'mydisk');

      final dl = client.rawDownloadUri('/p/v.mp4', algo: 'zip');
      expect(dl.queryParameters['file'], '/p/v.mp4');
      expect(dl.queryParameters['algo'], 'zip');
    });

    test('rawBundleDownloadUri repeats file= with full scoped paths', () {
      final (client, _) = makeClient((_) => MockAdapter.text(''));
      final uri = client
          .rawBundleDownloadUri('/My Photos', ['a b.jpg', 'rëp,ort.png']);
      expect(uri.path, '/api/resources/download');
      expect(uri.queryParameters['algo'], 'zip');
      // Each file is the full source-scoped path, sent as a repeated param.
      expect(uri.queryParametersAll['file'],
          ['/My Photos/a b.jpg', '/My Photos/rëp,ort.png']);
    });

    test('authHeaders carry the Bearer token', () {
      final (client, _) = makeClient((_) => MockAdapter.text(''));
      expect(client.authHeaders, {'Authorization': 'Bearer $liveToken'});
    });

    group('PATCH move/copy/rename (quantum items body)', () {
      test('move sends action=move with from/to source+path', () async {
        final (client, adapter) = makeClient(
            (_) => MockAdapter.json({'succeeded': [], 'failed': []}));
        await client.move('/src.txt', '/foo bar/bÉz');
        final req = adapter.requests.last;
        expect(req.method, 'PATCH');
        expect(req.uri.path, '/api/resources');
        final body = jsonDecode(req.data as String) as Map<String, dynamic>;
        expect(body['action'], 'move');
        expect(body['overwrite'], false);
        expect(body['rename'], false);
        expect(body['items'], [
          {
            'fromSource': 'mydisk',
            'fromPath': '/src.txt',
            'toSource': 'mydisk',
            'toPath': '/foo bar/bÉz',
          },
        ]);
      });

      test('copy honours overwrite; keepBoth maps to rename', () async {
        final (client, adapter) = makeClient(
            (_) => MockAdapter.json({'succeeded': [], 'failed': []}));
        await client.copy('/a', '/b', overwrite: true, keepBoth: true);
        final body =
            jsonDecode(adapter.requests.last.data as String) as Map<String, dynamic>;
        expect(body['action'], 'copy');
        expect(body['overwrite'], true);
        expect(body['rename'], true);
      });

      test('rename uses action=rename', () async {
        final (client, adapter) = makeClient(
            (_) => MockAdapter.json({'succeeded': [], 'failed': []}));
        await client.rename('/old name', '/new name');
        final body =
            jsonDecode(adapter.requests.last.data as String) as Map<String, dynamic>;
        expect(body['action'], 'rename');
        expect((body['items'] as List).single, {
          'fromSource': 'mydisk',
          'fromPath': '/old name',
          'toSource': 'mydisk',
          'toPath': '/new name',
        });
      });
    });
  });

  group('token validity', () {
    test('malformed tokens are invalid', () {
      expect(FileBrowserClient.isTokenValid('not-a-jwt'), isFalse);
      expect(FileBrowserClient.isTokenValid('a.b'), isFalse);
      expect(FileBrowserClient.isTokenValid('a.!!!.c'), isFalse);
    });

    test('expired tokens are invalid', () {
      expect(FileBrowserClient.isTokenValid(makeJwt(_nowS - 10)), isFalse);
    });

    test('near-margin tokens are invalid; comfortably-ahead are valid', () {
      // exp 30s ahead, default 1min margin -> invalid.
      expect(FileBrowserClient.isTokenValid(makeJwt(_nowS + 30)), isFalse);
      // exp 5min ahead, default 1min margin -> valid.
      expect(FileBrowserClient.isTokenValid(makeJwt(_nowS + 300)), isTrue);
      // custom zero margin: 30s ahead is now valid.
      expect(
        FileBrowserClient.isTokenValid(makeJwt(_nowS + 30),
            margin: Duration.zero),
        isTrue,
      );
    });
  });

  group('401 interceptor', () {
    test('401 -> renew -> retry succeeds transparently', () async {
      var resourceCalls = 0;
      var renewCalls = 0;
      final adapter = MockAdapter((o) {
        if (o.uri.path.endsWith('/api/auth/renew')) {
          renewCalls++;
          return MockAdapter.text(makeJwt(_nowS + 3600));
        }
        resourceCalls++;
        if (resourceCalls == 1) return MockAdapter.json({}, status: 401);
        return MockAdapter.json({
          'name': '/',
          'path': '/',
          'type': 'directory',
          'folders': [],
          'files': [],
        });
      });
      var expiredFired = false;
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(liveToken)
        ..setSource('mydisk')
        ..onSessionExpired = () => expiredFired = true;

      final res = await client.listDirectory('/');
      expect(res.isDir, isTrue);
      expect(renewCalls, 1);
      expect(resourceCalls, 2); // original + replay
      expect(expiredFired, isFalse);
    });

    test('401 then failed renew -> SessionExpiredException + callback', () async {
      final adapter = MockAdapter((o) {
        if (o.uri.path.endsWith('/api/auth/renew')) {
          return MockAdapter.json({}, status: 401);
        }
        return MockAdapter.json({}, status: 401);
      });
      var expiredFired = false;
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(liveToken)
        ..setSource('mydisk')
        ..onSessionExpired = () => expiredFired = true;

      try {
        await client.listDirectory('/');
        fail('expected a failure');
      } on DioException catch (e) {
        expect(e.error, isA<SessionExpiredException>());
      }
      expect(expiredFired, isTrue);
    });

    test('non-401 errors pass through without renew or callback', () async {
      var renewCalls = 0;
      final adapter = MockAdapter((o) {
        if (o.uri.path.endsWith('/api/auth/renew')) {
          renewCalls++;
          return MockAdapter.text(makeJwt(_nowS + 3600));
        }
        return MockAdapter.json({}, status: 500);
      });
      var expiredFired = false;
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(liveToken)
        ..setSource('mydisk')
        ..onSessionExpired = () => expiredFired = true;

      try {
        await client.listDirectory('/');
        fail('expected a failure');
      } on DioException catch (e) {
        expect(e.response?.statusCode, 500);
        expect(e.error, isNot(isA<SessionExpiredException>()));
      }
      expect(renewCalls, 0);
      expect(expiredFired, isFalse);
    });

    test('ensureFreshSession renews a near-expiry token without a 401',
        () async {
      var renewCalls = 0;
      final adapter = MockAdapter((o) {
        if (o.uri.path.endsWith('/api/auth/renew')) {
          renewCalls++;
          return MockAdapter.text(makeJwt(_nowS + 3600));
        }
        return MockAdapter.json({}, status: 200);
      });
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(makeJwt(_nowS + 30)); // within default 5min margin
      await client.ensureFreshSession();
      expect(renewCalls, 1);
    });
  });
}
