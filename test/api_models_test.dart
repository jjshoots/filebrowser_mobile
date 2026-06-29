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

    test('fromJsonOrNull degrades when no real capacity is reported', () {
      // A source's reduceIndex carries used/usedAlt/total; total<=0 => no gauge.
      expect(FbUsage.fromJsonOrNull({'total': 0, 'used': 0}), isNull);
      final u = FbUsage.fromJsonOrNull(
          {'total': 1024 * 1024, 'used': 512 * 1024, 'usedAlt': 600 * 1024});
      expect(u, isNotNull);
      expect(u!.total, 1024 * 1024);
      expect(u.used, 512 * 1024);
    });
  });

  group('FbSource', () {
    test('parses name + usage from a sources-endpoint entry', () {
      final s = FbSource.fromJson('mydisk', {
        'name': 'mydisk',
        'used': 512 * 1024,
        'usedAlt': 600 * 1024,
        'total': 1024 * 1024,
        'status': 'ready',
      });
      expect(s.name, 'mydisk');
      expect(s.usage, isNotNull);
      expect(s.usage!.used, 512 * 1024);
      expect(s.usage!.total, 1024 * 1024);
    });

    test('usage is null when the source reports no capacity', () {
      final s = FbSource.fromJson('empty', {'name': 'empty', 'total': 0});
      expect(s.name, 'empty');
      expect(s.usage, isNull);
    });
  });

  group('FbShare', () {
    test('parses a password-less, non-expiring list entry', () {
      final s = FbShare.fromJson({
        'hash': 'abc123',
        'path': '/docs/file.txt',
        'source': 'mydisk',
        'username': 'alice',
        'userID': 1,
        'expire': 0,
        'hasPassword': false,
        // quantum attaches extra fields the model ignores
        'downloadsLimit': 0,
        'shareType': 'normal',
      });
      expect(s.hash, 'abc123');
      expect(s.path, '/docs/file.txt');
      expect(s.source, 'mydisk');
      expect(s.username, 'alice');
      expect(s.hasPassword, isFalse);
      expect(s.token, isNull);
      expect(s.expire, 0);
      expect(s.expiresAt, isNull);
      expect(s.isExpired, isFalse);
    });

    // The server returns `token` only for password-protected shares; the parser
    // maps it when present and leaves it null otherwise.
    test('maps the bypass token of a password-protected share', () {
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
    test('parses a hit and derives the name; isDir follows type', () {
      final r = FbSearchResult.fromJson(
          {'type': 'text', 'path': '/a/b/c.txt', 'source': 'mydisk'});
      expect(r.isDir, isFalse);
      expect(r.path, '/a/b/c.txt');
      expect(r.name, 'c.txt');
      expect(r.source, 'mydisk');
    });

    test('directory hit (type=directory, trailing slash) names the folder', () {
      final r = FbSearchResult.fromJson({'type': 'directory', 'path': '/a/b/'});
      expect(r.isDir, isTrue);
      expect(r.name, 'b');
    });
  });

  group('FbServerCaps', () {
    test('parses signup (auth.methods.password) and frontend branding name', () {
      final caps = FbServerCaps.fromJson({
        'auth': {
          'methods': {
            'password': {'signup': true},
          },
        },
        'frontend': {'name': 'My Files'},
      });
      expect(caps.signup, isTrue);
      expect(caps.name, 'My Files');
    });

    test('tolerates flat keys and applies defaults when missing', () {
      final caps = FbServerCaps.fromJson({'signup': false, 'name': ''});
      expect(caps.signup, isFalse);
      expect(caps.name, '');
    });
  });

  group('FbResource quantum directory shape', () {
    test('merges folders+files into items and computes child paths', () {
      final dir = FbResource.fromJson({
        'name': 'photos',
        'path': '/photos/',
        'type': 'directory',
        'source': 'mydisk',
        'folders': [
          {'name': '2024', 'type': 'directory'},
        ],
        'files': [
          {'name': 'a.jpg', 'type': 'image', 'size': 10},
          {'name': 'b.txt', 'type': 'text', 'size': 2},
        ],
      });
      expect(dir.isDir, isTrue);
      expect(dir.items.length, 3);
      // Folders first, then files (matches the web client ordering).
      final folder = dir.items[0];
      expect(folder.name, '2024');
      expect(folder.isDir, isTrue);
      expect(folder.path, '/photos/2024/'); // trailing slash for directories
      final img = dir.items[1];
      expect(img.name, 'a.jpg');
      expect(img.isDir, isFalse);
      expect(img.path, '/photos/a.jpg');
      expect(img.isImage, isTrue);
    });

    test('computes child paths at the source root', () {
      final dir = FbResource.fromJson({
        'name': '/',
        'path': '/',
        'type': 'directory',
        'folders': [
          {'name': 'docs', 'type': 'directory'},
        ],
        'files': [
          {'name': 'readme.md', 'type': 'text'},
        ],
      });
      expect(dir.items[0].path, '/docs/');
      expect(dir.items[1].path, '/readme.md');
    });
  });

  group('FbResource type helpers', () {
    FbResource file({String name = 'f', String? ext, String? type}) =>
        FbResource(
            path: '/$name', name: name, size: 1, isDir: false,
            extension: ext, type: type);

    test('isAudio by extension and by type field', () {
      expect(file(name: 'song.mp3').isAudio, isTrue);
      expect(file(name: 'song.FLAC').isAudio, isTrue); // case-insensitive
      expect(file(name: 'clip', ext: '.m4a').isAudio, isTrue);
      expect(file(name: 'voice', type: 'audio').isAudio, isTrue);
      expect(file(name: 'song.mp3').isPdf, isFalse);
      expect(file(name: 'song.mp3').isText, isFalse);
    });

    test('isPdf by extension and by type field', () {
      expect(file(name: 'doc.pdf').isPdf, isTrue);
      expect(file(name: 'doc', type: 'pdf').isPdf, isTrue);
      expect(file(name: 'doc.txt').isPdf, isFalse);
    });

    test('isText covers common code/markup exts and the type fields', () {
      expect(file(name: 'readme.md').isText, isTrue);
      expect(file(name: 'main.dart').isText, isTrue);
      expect(file(name: 'data.json').isText, isTrue);
      expect(file(name: 'notes', type: 'text').isText, isTrue);
      expect(file(name: 'locked', type: 'textImmutable').isText, isTrue);
      expect(file(name: 'pic.jpg').isText, isFalse);
    });

    test('directories are never typed as media/openable kinds', () {
      final dir = FbResource(
          path: '/d', name: 'd', size: 0, isDir: true, type: 'audio');
      expect(dir.isAudio, isFalse);
      expect(dir.isPdf, isFalse);
      expect(dir.isText, isFalse);
    });
  });

  group('FbResource.activation (open-with routing)', () {
    FbResource res(
            {required String name, bool isDir = false, String? type}) =>
        FbResource(
            path: '/$name', name: name, size: 1, isDir: isDir, type: type);

    test('folders navigate', () {
      expect(res(name: 'sub', isDir: true).activation,
          ResourceActivation.openFolder);
    });

    test('images and videos open the in-app viewer', () {
      expect(res(name: 'p.png').activation, ResourceActivation.viewImage);
      expect(res(name: 'm.mp4').activation, ResourceActivation.playVideo);
    });

    test('pdf/text/audio and unknown types open externally', () {
      expect(res(name: 'd.pdf').activation, ResourceActivation.openExternally);
      expect(res(name: 'r.md').activation, ResourceActivation.openExternally);
      expect(res(name: 's.mp3').activation, ResourceActivation.openExternally);
      expect(res(name: 'x.bin').activation, ResourceActivation.openExternally);
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
