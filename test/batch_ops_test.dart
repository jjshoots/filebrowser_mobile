import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/ui/batch_ops.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
String _jwt(int exp) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': exp, 'user': {'username': 'u', 'perm': {'create': true, 'modify': true}}})}.sig';
int get _nowS => DateTime.now().millisecondsSinceEpoch ~/ 1000;

FbResource _file(String path) => FbResource(
    path: path, name: path.split('/').last, size: 1, isDir: false);
FbResource _dir(String path) =>
    FbResource(path: path, name: path.split('/').last, size: 0, isDir: true);

void main() {
  group('destinationPath', () {
    test('moves an item into a target directory by basename', () {
      expect(destinationPath('/a/b/x.jpg', '/c'), '/c/x.jpg');
    });
    test('root source and root destination', () {
      expect(destinationPath('/x.jpg', '/'), '/x.jpg');
      expect(destinationPath('/a/x.jpg', '/'), '/x.jpg');
    });
    test('preserves unicode and spaces verbatim', () {
      expect(destinationPath('/álbum/föö bar.png', '/dëst'),
          '/dëst/föö bar.png');
    });
    test('trailing slashes on either side are normalised', () {
      expect(destinationPath('/a/folder/', '/dest/'), '/dest/folder');
    });
  });

  group('isMoveIntoSelfOrDescendant', () {
    test('into itself is blocked', () {
      expect(isMoveIntoSelfOrDescendant('/a', '/a'), isTrue);
    });
    test('into a descendant is blocked', () {
      expect(isMoveIntoSelfOrDescendant('/a', '/a/b'), isTrue);
      expect(isMoveIntoSelfOrDescendant('/a/b', '/a/b/c/d'), isTrue);
    });
    test('a sibling with a shared name prefix is allowed', () {
      expect(isMoveIntoSelfOrDescendant('/a', '/ab'), isFalse);
    });
    test('unrelated and parent destinations are allowed', () {
      expect(isMoveIntoSelfOrDescendant('/a/b', '/c'), isFalse);
      expect(isMoveIntoSelfOrDescendant('/a/b', '/a'), isFalse);
    });
    test('root source is never self/descendant', () {
      expect(isMoveIntoSelfOrDescendant('/', '/a'), isFalse);
    });
  });

  group('runTransferBatch (conflict + overwrite plumbing)', () {
    /// Builds a client whose `resourceExists` answers from [existing] and
    /// records every PATCH; copy/move return 200.
    (FileBrowserClient, MockAdapter) clientWith(Set<String> existing) {
      final adapter = MockAdapter((o) {
        if (o.method == 'GET') {
          // resourceExists probe: GET /api/resources?source=&path=<p>
          final path = o.uri.queryParameters['path'] ?? '';
          return existing.contains(path)
              ? MockAdapter.json({'path': path})
              : MockAdapter.json({}, status: 404);
        }
        // PATCH move/copy
        return MockAdapter.json({'succeeded': [], 'failed': []});
      });
      final client =
          FileBrowserClient(baseUrl: 'https://x.example', adapter: adapter)
            ..adoptToken(_jwt(_nowS + 3600))
            ..setSource('mydisk');
      return (client, adapter);
    }

    List<RequestOptions> patches(MockAdapter a) =>
        a.requests.where((r) => r.method == 'PATCH').toList();

    /// The single move/copy item descriptor from a PATCH's JSON body.
    Map<String, dynamic> item0(RequestOptions r) {
      final body = jsonDecode(r.data as String) as Map<String, dynamic>;
      return (body['items'] as List).single as Map<String, dynamic>;
    }

    Map<String, dynamic> body(RequestOptions r) =>
        jsonDecode(r.data as String) as Map<String, dynamic>;

    test('no conflict -> copy with overwrite=false, never prompts', () async {
      final (client, adapter) = clientWith({});
      var prompts = 0;
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.copy,
        items: [_file('/a/x.txt'), _file('/a/y.txt')],
        destDir: '/dest',
        onConflict: (_, __) async {
          prompts++;
          return ConflictChoice.overwrite;
        },
      );
      expect(prompts, 0);
      expect(res.succeeded, 2);
      final ps = patches(adapter);
      expect(ps, hasLength(2));
      expect(ps.every((r) => body(r)['action'] == 'copy'), isTrue);
      expect(ps.every((r) => body(r)['overwrite'] == false), isTrue);
      expect(ps.every((r) => body(r)['rename'] == false), isTrue);
      expect(ps.map((r) => item0(r)['toPath']),
          containsAll(['/dest/x.txt', '/dest/y.txt']));
    });

    test('conflict + overwrite -> PATCH carries overwrite=true', () async {
      final (client, adapter) = clientWith({'/dest/x.txt'});
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.move,
        items: [_file('/a/x.txt')],
        destDir: '/dest',
        onConflict: (_, __) async => ConflictChoice.overwrite,
      );
      expect(res.succeeded, 1);
      final ps = patches(adapter);
      expect(ps, hasLength(1));
      expect(body(ps.single)['action'], 'move');
      expect(body(ps.single)['overwrite'], true);
      expect(body(ps.single)['rename'], false);
    });

    test('conflict + skip -> no PATCH issued for that item', () async {
      final (client, adapter) = clientWith({'/dest/x.txt'});
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.copy,
        items: [_file('/a/x.txt')],
        destDir: '/dest',
        onConflict: (_, __) async => ConflictChoice.skip,
      );
      expect(res.skipped, 1);
      expect(res.succeeded, 0);
      expect(patches(adapter), isEmpty);
    });

    test('conflict + keepBoth -> PATCH carries rename=true (server versions)',
        () async {
      final (client, adapter) = clientWith({'/dest/x.txt'});
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.copy,
        items: [_file('/a/x.txt')],
        destDir: '/dest',
        onConflict: (_, __) async => ConflictChoice.keepBoth,
      );
      expect(res.succeeded, 1);
      final ps = patches(adapter);
      expect(ps, hasLength(1));
      // The original destination is sent; the server auto-versions it.
      expect(item0(ps.single)['toPath'], '/dest/x.txt');
      expect(body(ps.single)['rename'], true);
      expect(body(ps.single)['overwrite'], false);
    });

    test('overwrite onto itself (same folder) is skipped, never sent',
        () async {
      // Copying a file into the directory it already lives in resolves to
      // target == source; the server rejects this self-copy with a 500, so the
      // batch must treat an "overwrite" choice here as a no-op skip.
      final (client, adapter) = clientWith({'/a/x.txt'});
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.copy,
        items: [_file('/a/x.txt')],
        destDir: '/a',
        onConflict: (_, __) async => ConflictChoice.overwrite,
      );
      expect(res.skipped, 1);
      expect(res.succeeded, 0);
      expect(patches(adapter), isEmpty);
    });

    test('returning null from the resolver aborts the remainder', () async {
      final (client, adapter) = clientWith({'/dest/x.txt', '/dest/y.txt'});
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.copy,
        items: [_file('/a/x.txt'), _file('/a/y.txt')],
        destDir: '/dest',
        onConflict: (_, __) async => null, // user cancels on first conflict
      );
      expect(res.aborted, isTrue);
      expect(patches(adapter), isEmpty);
    });

    test('move into self/descendant is recorded as a failure, never sent',
        () async {
      final (client, adapter) = clientWith({});
      final res = await runTransferBatch(
        client: client,
        op: TransferOp.move,
        items: [_dir('/a')],
        destDir: '/a/b', // into a descendant
        onConflict: (_, __) async => ConflictChoice.overwrite,
      );
      expect(res.failures, hasLength(1));
      expect(res.succeeded, 0);
      expect(patches(adapter), isEmpty);
    });
  });
}
