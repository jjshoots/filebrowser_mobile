import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/ui/breadcrumbs.dart';

void main() {
  group('breadcrumbsFor', () {
    test('root path yields just the root crumb', () {
      expect(breadcrumbsFor('/'), [(label: 'Files', path: '/')]);
    });

    test('empty string is treated as root', () {
      expect(breadcrumbsFor(''), [(label: 'Files', path: '/')]);
    });

    test('nested path accumulates absolute paths per segment', () {
      expect(breadcrumbsFor('/photos/2024/summer'), [
        (label: 'Files', path: '/'),
        (label: 'photos', path: '/photos'),
        (label: '2024', path: '/photos/2024'),
        (label: 'summer', path: '/photos/2024/summer'),
      ]);
    });

    test('trailing and doubled slashes collapse to empty segments', () {
      expect(breadcrumbsFor('/a/b/'), [
        (label: 'Files', path: '/'),
        (label: 'a', path: '/a'),
        (label: 'b', path: '/a/b'),
      ]);
      expect(breadcrumbsFor('/a//b'), [
        (label: 'Files', path: '/'),
        (label: 'a', path: '/a'),
        (label: 'b', path: '/a/b'),
      ]);
    });

    test('preserves unicode and spaces verbatim', () {
      expect(breadcrumbsFor('/Ünïcode/My Photos/夏'), [
        (label: 'Files', path: '/'),
        (label: 'Ünïcode', path: '/Ünïcode'),
        (label: 'My Photos', path: '/Ünïcode/My Photos'),
        (label: '夏', path: '/Ünïcode/My Photos/夏'),
      ]);
    });

    test('honours a custom root label', () {
      expect(breadcrumbsFor('/', rootLabel: 'Home').first.label, 'Home');
    });
  });
}
