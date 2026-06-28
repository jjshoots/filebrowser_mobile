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

  group('sorting', () {
    test('naturalCompare orders numbers numerically, case-insensitively', () {
      final names = ['img10.jpg', 'img2.jpg', 'IMG1.jpg'];
      names.sort(naturalCompare);
      expect(names, ['IMG1.jpg', 'img2.jpg', 'img10.jpg']);
    });

    FbResource dir(String n) =>
        FbResource(path: '/$n', name: n, size: 0, isDir: true);
    FbResource file(String n, int size) =>
        FbResource(path: '/$n', name: n, size: size, isDir: false);

    final listing = FbResource(
      path: '/',
      name: '/',
      size: 0,
      isDir: true,
      items: [file('b10.txt', 30), file('b2.txt', 10), dir('Zeta'), dir('alpha')],
    );

    test('name asc: folders first (natural), then files (natural)', () {
      final names = listing.sortedBy(SortKey.name, true).map((e) => e.name).toList();
      expect(names, ['alpha', 'Zeta', 'b2.txt', 'b10.txt']);
    });

    test('name desc: folders still grouped first, names reversed', () {
      final names = listing.sortedBy(SortKey.name, false).map((e) => e.name).toList();
      expect(names, ['Zeta', 'alpha', 'b10.txt', 'b2.txt']);
    });

    test('size asc sorts files by size (folders first)', () {
      final names = listing.sortedBy(SortKey.size, true).map((e) => e.name).toList();
      expect(names.sublist(2), ['b2.txt', 'b10.txt']); // 10 then 30
    });
  });
}
