@Tags(['integration'])
library;

// End-to-end API tests against a REAL running filebrowser-quantum server.
//
// These are pure-Dart (no emulator / no Flutter widget binding): they point a
// real [FileBrowserClient] at FB_TEST_URL (default http://localhost:8080), log
// in as admin/admin12345, select source `files`, and exercise the migrated
// quantum contracts end-to-end — list, mkdir, upload, download (single +
// repeated-`file=` bundle), checksum, move, copy, rename, delete, search, and
// share create/list/delete.
//
// They are tagged `integration` and EXCLUDED from a bare `flutter test`
// (see dart_test.yaml). Run them with a server up via:
//   flutter test --tags integration
//   make e2e   (boots tool/serve.sh first)
//
// Everything is created under a unique temp dir at the source root and removed
// in tearDownAll, so the run is self-cleaning and re-runnable.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

// Target server is configurable and defaults to a LOCAL test server — never a
// hardcoded real server. CI/`make e2e` set FB_TEST_URL.
String get _baseUrl =>
    Platform.environment['FB_TEST_URL'] ?? 'http://localhost:8080';

void main() {
  final baseUrl = _baseUrl;
  late FileBrowserClient client;
  late Dio raw; // bare dio for upload (raw body) + download (bytes) probes.

  // Unique workspace at the source root so concurrent/repeat runs never clash.
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final workDir = '/qm_ci_$stamp'; // leading-slash = source root
  String p(String name) => '$workDir/$name';

  setUpAll(() async {
    client = FileBrowserClient(baseUrl: baseUrl);
    await client.login('admin', 'admin12345');
    client.setSource('files');
    raw = Dio();
    // Seed the workspace.
    await client.makeDirectory(workDir);
  });

  tearDownAll(() async {
    // Best-effort cleanup of everything this run created.
    try {
      await client.delete(workDir);
    } catch (_) {/* already gone */}
  });

  Future<void> upload(String path, List<int> bytes,
      {bool override = true}) async {
    await raw.postUri<void>(
      client.uploadUri(path, override: override),
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          ...client.authHeaders,
          Headers.contentLengthHeader: bytes.length,
        },
        contentType: 'application/octet-stream',
      ),
    );
  }

  Future<Uint8List> download(Uri uri) async {
    final resp = await raw.getUri<List<int>>(
      uri,
      options: Options(
        headers: client.authHeaders,
        responseType: ResponseType.bytes,
      ),
    );
    return Uint8List.fromList(resp.data!);
  }

  test('login adopts a JWT and reports authenticated', () {
    expect(client.isAuthenticated, isTrue);
    expect(client.source, 'files');
  });

  test('listDirectory returns the seeded source root tree', () async {
    final root = await client.listDirectory('/');
    expect(root.isDir, isTrue);
    final names = root.items.map((e) => e.name).toSet();
    // From tool/serve.sh seed data.
    expect(names, contains('Documents'));
    expect(names, contains('Photos'));
  });

  test('mkdir then resourceExists / list reflects the new folder', () async {
    final dir = p('sub');
    await client.makeDirectory(dir);
    expect(await client.resourceExists(dir), isTrue);
    final listed = await client.listDirectory(workDir);
    expect(listed.items.map((e) => e.name), contains('sub'));
  });

  test('upload then download round-trips the bytes', () async {
    final body = utf8.encode('quantum round trip $stamp');
    final file = p('hello.txt');
    await upload(file, body);
    expect(await client.resourceExists(file), isTrue);

    final got = await download(client.rawDownloadUri(file));
    expect(utf8.decode(got), 'quantum round trip $stamp');
  });

  test('upload without override returns 409 on conflict', () async {
    final file = p('conflict.txt');
    await upload(file, utf8.encode('first'));
    await expectLater(
      () => upload(file, utf8.encode('second'), override: false),
      throwsA(isA<DioException>().having(
        (e) => e.response?.statusCode, 'status', 409)),
    );
  });

  test('checksum matches the fixture sha256', () async {
    // Fixed content whose sha256 is precomputed, so no hashing dep is needed.
    final body = utf8.encode('quantum-checksum-fixture\n');
    const expected =
        'c28e5c29a5c2b64a0d172625490ec4c08cc694716e0d32d2ec38ee219af764a2';
    final file = p('sum.txt');
    await upload(file, body);
    final remote = await client.checksum(file, algo: 'sha256');
    expect(remote, expected);
  });

  test('bundle download (repeated file=) returns a zip archive', () async {
    await upload(p('a.txt'), utf8.encode('aaa'));
    await upload(p('b.txt'), utf8.encode('bbb'));
    final bytes =
        await download(client.rawBundleDownloadUri(workDir, ['a.txt', 'b.txt']));
    // Local zip files start with the "PK\x03\x04" signature.
    expect(bytes.length, greaterThan(4));
    expect(bytes.sublist(0, 2), [0x50, 0x4B]); // 'P','K'
  });

  test('copy duplicates a file, leaving the original', () async {
    await upload(p('orig.txt'), utf8.encode('orig'));
    await client.copy(p('orig.txt'), p('copy.txt'));
    expect(await client.resourceExists(p('orig.txt')), isTrue);
    expect(await client.resourceExists(p('copy.txt')), isTrue);
  });

  test('move relocates a file into a subdir', () async {
    await upload(p('movable.txt'), utf8.encode('move me'));
    await client.makeDirectory(p('dest'));
    await client.move(p('movable.txt'), p('dest/movable.txt'));
    expect(await client.resourceExists(p('movable.txt')), isFalse);
    expect(await client.resourceExists(p('dest/movable.txt')), isTrue);
  });

  test('rename changes a file name in place', () async {
    await upload(p('before.txt'), utf8.encode('x'));
    await client.rename(p('before.txt'), p('after.txt'));
    expect(await client.resourceExists(p('before.txt')), isFalse);
    expect(await client.resourceExists(p('after.txt')), isTrue);
  });

  test('delete removes a file', () async {
    await upload(p('doomed.txt'), utf8.encode('x'));
    await client.delete(p('doomed.txt'));
    expect(await client.resourceExists(p('doomed.txt')), isFalse);
  });

  test('search finds an uploaded file by a unique token', () async {
    // Token must be >= 3 chars (quantum rejects shorter queries with 400).
    final token = 'zqx$stamp';
    await upload(p('$token.txt'), utf8.encode('searchable'));
    // Allow the index to pick up the new file.
    List<FbSearchResult> hits = const [];
    for (var i = 0; i < 20; i++) {
      hits = await client.search('/', token);
      if (hits.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    expect(hits, isNotEmpty, reason: 'search did not index $token in time');
    expect(hits.any((h) => h.path.contains(token)), isTrue);
  });

  test('share create / list / delete lifecycle', () async {
    final file = p('shared.txt');
    await upload(file, utf8.encode('share me'));

    final created = await client.createShare(file);
    expect(created.hash, isNotEmpty);
    expect(created.path.contains('shared.txt'), isTrue);

    final all = await client.listShares();
    expect(all.any((s) => s.hash == created.hash), isTrue);

    await client.deleteShare(created.hash);
    final after = await client.listShares();
    expect(after.any((s) => s.hash == created.hash), isFalse);
  });

  test('listSources / diskUsage report the files source', () async {
    final sources = await client.listSources();
    expect(sources.keys, contains('files'));
    final usage = await client.diskUsage();
    // Disposable filesystem always reports a capacity.
    expect(usage, isNotNull);
    expect(usage!.total, greaterThan(0));
  });
}
