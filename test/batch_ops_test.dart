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
    /// records every PATCH; copy/move/makeDir return 200.
    (FileBrowserClient, MockAdapter) clientWith(Set<String> existing) {
      final adapter = MockAdapter((o) {
        final isPatch = o.method == 'PATCH';
        if (!isPatch && o.method == 'GET') {
          // resourceExists probe against /api/resources/<path>
          final decoded = Uri.decodeFull(o.uri.path).replaceFirst(
              RegExp(r'^.*/api/resources'), '');
          return existing.contains(decoded)
              ? MockAdapter.json({'path': decoded})
              : MockAdapter.json({}, status: 404);
        }
        return MockAdapter.text('');
      });
      final client =
          FileBrowserClient(baseUrl: 'https://x.example', adapter: adapter)
            ..adoptToken(_jwt(_nowS + 3600));
      return (client, adapter);
    }

    List<RequestOptions> patches(MockAdapter a) =>
        a.requests.where((r) => r.method == 'PATCH').toList();

    test('no conflict -> copy with override=false, never prompts', () async {
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
      expect(ps.every((r) => r.uri.queryParameters['action'] == 'copy'), isTrue);
      expect(ps.every((r) => r.uri.queryParameters['override'] == 'false'),
          isTrue);
      expect(ps.map((r) => r.uri.queryParameters['destination']),
          containsAll(['/dest/x.txt', '/dest/y.txt']));
    });

    test('conflict + overwrite -> PATCH carries override=true', () async {
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
      expect(ps.single.uri.queryParameters['action'], 'rename'); // move
      expect(ps.single.uri.queryParameters['override'], 'true');
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

    test('conflict + keepBoth -> retargets to a versioned, free name',
        () async {
      // /dest/x.txt and /dest/x(1).txt taken; x(2).txt is free.
      final (client, adapter) =
          clientWith({'/dest/x.txt', '/dest/x(1).txt'});
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
      expect(ps.single.uri.queryParameters['destination'], '/dest/x(2).txt');
      expect(ps.single.uri.queryParameters['override'], 'false');
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
