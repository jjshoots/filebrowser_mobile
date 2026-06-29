import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

/// Build a JWT with the given expiry (seconds since epoch).
String makeJwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch, 'user': {'username': 'u', 'perm': {'create': true, 'modify': true}}})}.sig';

int get _nowS => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  // A long-lived token so requests are "authenticated" and not auto-renewed.
  final liveToken = makeJwt(_nowS + 3600);

  /// Returns a client whose every request is answered by [handler], with
  /// [liveToken] already adopted.
  (FileBrowserClient, MockAdapter) makeClient(
    ResponseBody Function(RequestOptions) handler, {
    String base = 'https://demo.example.com',
  }) {
    final adapter = MockAdapter(handler);
    final client = FileBrowserClient(baseUrl: base, adapter: adapter)
      ..adoptToken(liveToken);
    return (client, adapter);
  }

  group('URL construction', () {
    test('search encodes the path and carries the query', () async {
      final (client, adapter) =
          makeClient((_) => MockAdapter.text('{"dir":false,"path":"a.txt"}\n'));
      await client.search('/My Photos/2024', 'rëport space');
      final uri = adapter.requests.last.uri;
      expect(adapter.requests.last.method, 'GET');
      expect(uri.toString(),
          contains('/api/search/My%20Photos/2024'));
      expect(uri.queryParameters['query'], 'rëport space');
    });

    test('diskUsage hits /api/usage/<path>', () async {
      final (client, adapter) =
          makeClient((_) => MockAdapter.json({'total': 10, 'used': 4}));
      await client.diskUsage('/dir with space');
      expect(adapter.requests.last.method, 'GET');
      expect(adapter.requests.last.uri.toString(),
          contains('/api/usage/dir%20with%20space'));
    });

    test('listShares hits /api/shares (no trailing slash)', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json([]));
      await client.listShares();
      expect(adapter.requests.last.uri.toString(),
          'https://demo.example.com/api/shares');
    });

    test('createShare POSTs JSON body to /api/share/<path>', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json({
            'hash': 'h',
            'path': '/p',
            'userID': 1,
            'expire': 0,
            'hasPassword': true,
          }));
      final share = await client.createShare('/p',
          password: 'secret', expires: '2', unit: 'days');
      final req = adapter.requests.last;
      expect(req.method, 'POST');
      expect(req.uri.toString(), contains('/api/share/p'));
      final body = jsonDecode(req.data as String) as Map<String, dynamic>;
      expect(body, {'password': 'secret', 'expires': '2', 'unit': 'days'});
      // This server version never returns a bypass token on creation.
      expect(share.token, isNull);
      expect(share.hasPassword, isTrue);
    });

    test('deleteShare hits /api/share/<hash>', () async {
      final (client, adapter) = makeClient((_) => MockAdapter.text(''));
      await client.deleteShare('aB_9-x');
      expect(adapter.requests.last.method, 'DELETE');
      expect(adapter.requests.last.uri.toString(),
          contains('/api/share/aB_9-x'));
    });

    test('getSettings hits /api/settings', () async {
      final (client, adapter) =
          makeClient((_) => MockAdapter.json({'signup': false}));
      await client.getSettings();
      expect(adapter.requests.last.uri.toString(),
          'https://demo.example.com/api/settings');
    });

    test('checksum uses /api/resources/<path>?checksum= and reads the digest',
        () async {
      final (client, adapter) = makeClient((_) => MockAdapter.json({
            'path': '/a',
            'checksums': {'sha256': 'deadbeef'},
          }));
      final sum = await client.checksum('/a/b c.bin', algo: 'sha256');
      final uri = adapter.requests.last.uri;
      expect(uri.toString(), contains('/api/resources/a/b%20c.bin'));
      expect(uri.queryParameters['checksum'], 'sha256');
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

    test('rawBundleDownloadUri lists files under the dir with algo=zip', () {
      final (client, _) = makeClient((_) => MockAdapter.text(''));
      final uri = client
          .rawBundleDownloadUri('/My Photos', ['a b.jpg', 'rëp,ort.png']);
      expect(uri.path, contains('/api/raw/My%20Photos'));
      expect(uri.queryParameters['algo'], 'zip');
      // Names are double-encoded (the server unescapes the `files` value, then
      // each comma-split entry, a second time). One decode layer is visible
      // here; commas inside a name survive as %2C so the split can't mis-cut.
      expect(uri.queryParameters['files'], 'a%20b.jpg,r%C3%ABp%2Cort.png');
    });

    group('PATCH destination (copy/move/rename)', () {
      test('move double-encodes the destination and preserves separators',
          () async {
        final (client, adapter) = makeClient((_) => MockAdapter.text(''));
        await client.move('/src.txt', '/foo bar/bÉz');
        final req = adapter.requests.last;
        expect(req.method, 'PATCH');
        expect(req.uri.toString(), contains('/api/resources/src.txt'));
        expect(req.uri.queryParameters['action'], 'rename');
        // queryParameters decodes one layer; the pre-encoded form survives.
        expect(req.uri.queryParameters['destination'], '/foo%20bar/b%C3%89z');
        // …and the wire form carries the second encoding layer the server
        // unescapes twice.
        expect(req.uri.query, contains('%2520'));
        expect(req.uri.queryParameters['override'], 'false');
      });

      test('copy uses action=copy and honours overwrite', () async {
        final (client, adapter) = makeClient((_) => MockAdapter.text(''));
        await client.copy('/a', '/b', overwrite: true);
        final q = adapter.requests.last.uri.queryParameters;
        expect(q['action'], 'copy');
        expect(q['override'], 'true');
        expect(q['destination'], '/b');
      });

      test('rename delegates to move (action=rename)', () async {
        final (client, adapter) = makeClient((_) => MockAdapter.text(''));
        await client.rename('/old name', '/new name');
        final q = adapter.requests.last.uri.queryParameters;
        expect(q['action'], 'rename');
        expect(q['destination'], '/new%20name');
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
        if (o.uri.path.endsWith('/api/renew')) {
          renewCalls++;
          return MockAdapter.text(makeJwt(_nowS + 3600));
        }
        resourceCalls++;
        if (resourceCalls == 1) return MockAdapter.json({}, status: 401);
        return MockAdapter.json(
            {'path': '/', 'name': '/', 'size': 0, 'isDir': true, 'items': []});
      });
      var expiredFired = false;
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(liveToken)
        ..onSessionExpired = () => expiredFired = true;

      final res = await client.listDirectory('/');
      expect(res.isDir, isTrue);
      expect(renewCalls, 1);
      expect(resourceCalls, 2); // original + replay
      expect(expiredFired, isFalse);
    });

    test('401 then failed renew -> SessionExpiredException + callback', () async {
      final adapter = MockAdapter((o) {
        if (o.uri.path.endsWith('/api/renew')) {
          return MockAdapter.json({}, status: 401);
        }
        return MockAdapter.json({}, status: 401);
      });
      var expiredFired = false;
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(liveToken)
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
        if (o.uri.path.endsWith('/api/renew')) {
          renewCalls++;
          return MockAdapter.text(makeJwt(_nowS + 3600));
        }
        return MockAdapter.json({}, status: 500);
      });
      var expiredFired = false;
      final client = FileBrowserClient(
          baseUrl: 'https://demo.example.com', adapter: adapter)
        ..adoptToken(liveToken)
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
        if (o.uri.path.endsWith('/api/renew')) {
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
