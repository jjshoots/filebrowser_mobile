import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/models.dart';

void main() {
  group('formatBytes', () {
    test('bytes under 1 KiB stay in B', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('scales through KB/MB/GB/TB with one decimal', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes(1024 * 1024 * 1024 * 1024), '1.0 TB');
    });
  });

  group('FbUsage', () {
    test('parses total/used and derives fraction + human sizes', () {
      final u = FbUsage.fromJson({'total': 1024 * 1024, 'used': 512 * 1024});
      expect(u.total, 1024 * 1024);
      expect(u.used, 512 * 1024);
      expect(u.usedFraction, closeTo(0.5, 1e-9));
      expect(u.free, 512 * 1024);
      expect(u.usedHuman, '512.0 KB');
      expect(u.totalHuman, '1.0 MB');
    });

    test('zero total yields zero fraction (no divide-by-zero)', () {
      final u = FbUsage.fromJson({'total': 0, 'used': 0});
      expect(u.usedFraction, 0);
      expect(u.free, 0);
    });
  });

  group('FbShare', () {
    test('parses a password-less, non-expiring list entry', () {
      final s = FbShare.fromJson({
        'hash': 'abc123',
        'path': '/docs/file.txt',
        'userID': 1,
        'expire': 0,
        'hasPassword': false,
      });
      expect(s.hash, 'abc123');
      expect(s.path, '/docs/file.txt');
      expect(s.hasPassword, isFalse);
      expect(s.token, isNull);
      expect(s.expire, 0);
      expect(s.expiresAt, isNull);
      expect(s.isExpired, isFalse);
    });

    // This server version never emits `token`, but the parser keeps the field
    // nullable for forward-compat: if a future server adds it, fromJson maps it.
    test('forward-compat: maps a token field when present', () {
      final s = FbShare.fromJson({
        'hash': 'h-_9',
        'path': '/p',
        'userID': 2,
        'expire': 4102444800, // year 2100
        'hasPassword': true,
        'token': 'bypass-token',
      });
      expect(s.hasPassword, isTrue);
      expect(s.token, 'bypass-token');
      expect(s.expiresAt, isNotNull);
      expect(s.isExpired, isFalse);
    });

    test('detects an already-expired share', () {
      final s = FbShare.fromJson({
        'hash': 'x',
        'path': '/p',
        'expire': 1, // 1970
        'hasPassword': false,
      });
      expect(s.isExpired, isTrue);
    });
  });

  group('FbSearchResult', () {
    test('parses a streamed hit and derives the name', () {
      final r = FbSearchResult.fromJson({'dir': false, 'path': 'a/b/c.txt'});
      expect(r.isDir, isFalse);
      expect(r.path, 'a/b/c.txt');
      expect(r.name, 'c.txt');
    });

    test('directory hit with trailing slash names the folder', () {
      final r = FbSearchResult.fromJson({'dir': true, 'path': 'a/b/'});
      expect(r.isDir, isTrue);
      expect(r.name, 'b');
    });
  });

  group('FbServerCaps', () {
    test('parses branding name, signup, createUserDir and tus', () {
      final caps = FbServerCaps.fromJson({
        'signup': true,
        'createUserDir': true,
        'branding': {'name': 'My Files'},
        'tus': {'chunkSize': 5242880, 'retryCount': 3},
      });
      expect(caps.signup, isTrue);
      expect(caps.createUserDir, isTrue);
      expect(caps.name, 'My Files');
      expect(caps.tus.chunkSize, 5242880);
      expect(caps.tus.retryCount, 3);
    });

    test('applies tus defaults when missing/zero', () {
      final caps = FbServerCaps.fromJson({'signup': false});
      expect(caps.name, '');
      expect(caps.tus.chunkSize, 10 * 1024 * 1024);
      expect(caps.tus.retryCount, 5);
    });
  });

  group('FbResource.modifiedAt', () {
    test('parses an ISO-8601 timestamp', () {
      final r = FbResource.fromJson({
        'path': '/f.txt',
        'name': 'f.txt',
        'size': 1,
        'isDir': false,
        'modified': '2026-06-29T12:00:00Z',
      });
      expect(r.modifiedAt, DateTime.utc(2026, 6, 29, 12));
    });

    test('null when absent or unparseable', () {
      expect(
        FbResource.fromJson({'path': '/a', 'name': 'a', 'size': 0, 'isDir': true})
            .modifiedAt,
        isNull,
      );
      expect(
        FbResource.fromJson({
          'path': '/a',
          'name': 'a',
          'size': 0,
          'isDir': true,
          'modified': 'not-a-date',
        }).modifiedAt,
        isNull,
      );
    });
  });
}
