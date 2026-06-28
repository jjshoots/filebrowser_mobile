import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/models.dart';

void main() {
  group('FbResource.fromJson', () {
    test('parses a directory listing with items', () {
      final res = FbResource.fromJson({
        'path': '/',
        'name': 'root',
        'size': 0,
        'isDir': true,
        'items': [
          {'path': '/b.txt', 'name': 'b.txt', 'size': 10, 'isDir': false},
          {'path': '/a', 'name': 'a', 'size': 0, 'isDir': true},
        ],
      });
      expect(res.isDir, isTrue);
      expect(res.items, hasLength(2));
    });

    test('sortedItems puts directories first, then alphabetical', () {
      final res = FbResource.fromJson({
        'path': '/',
        'name': 'root',
        'size': 0,
        'isDir': true,
        'items': [
          {'path': '/z.txt', 'name': 'z.txt', 'size': 1, 'isDir': false},
          {'path': '/Beta', 'name': 'Beta', 'size': 0, 'isDir': true},
          {'path': '/alpha', 'name': 'alpha', 'size': 0, 'isDir': true},
        ],
      });
      final names = res.sortedItems.map((e) => e.name).toList();
      expect(names, ['alpha', 'Beta', 'z.txt']);
    });

    test('tolerates a missing items field', () {
      final res = FbResource.fromJson({
        'path': '/f.txt',
        'name': 'f.txt',
        'size': 5,
        'isDir': false,
      });
      expect(res.items, isEmpty);
    });
  });
}
