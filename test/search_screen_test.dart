import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/ui/search_screen.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _jwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch, 'user': {'username': 'u', 'perm': {'create': true, 'modify': true}}})}.sig';

void main() {
  group('resolveSearchPath (relative hit + searched root -> absolute)', () {
    test('root scope: a bare child resolves under /', () {
      expect(resolveSearchPath('/', 'report.txt'), '/report.txt');
    });

    test('root scope: nested relative path', () {
      expect(resolveSearchPath('/', 'photos/2024/img.jpg'),
          '/photos/2024/img.jpg');
    });

    test('nested scope: hit is joined onto the search root', () {
      expect(resolveSearchPath('/photos', 'sub/img.jpg'),
          '/photos/sub/img.jpg');
    });

    test('deeper nested scope', () {
      expect(resolveSearchPath('/a/b', 'c/d.txt'), '/a/b/c/d.txt');
    });

    test('a trailing slash on a folder hit is stripped', () {
      expect(resolveSearchPath('/photos', 'albums/'), '/photos/albums');
    });

    test('a stray leading slash on the hit is treated as relative', () {
      expect(resolveSearchPath('/photos', '/sub/x.jpg'), '/photos/sub/x.jpg');
    });

    test('an empty hit resolves to the root itself', () {
      expect(resolveSearchPath('/photos', ''), '/photos');
      expect(resolveSearchPath('/', ''), '/');
    });

    test('unicode and spaces are preserved verbatim', () {
      expect(resolveSearchPath('/Mes Photos', 'été/plage.jpg'),
          '/Mes Photos/été/plage.jpg');
      expect(resolveSearchPath('/', 'résumé final.pdf'),
          '/résumé final.pdf');
    });
  });

  group('classifySearchResult (dir vs media vs other)', () {
    SearchTargetKind kind(String path, {bool dir = false}) =>
        classifySearchResult(FbSearchResult(path: path, isDir: dir));

    test('directories classify first, regardless of name', () {
      expect(kind('photos/holiday', dir: true), SearchTargetKind.directory);
      // even a dir whose name looks like an image extension
      expect(kind('weird.jpg', dir: true), SearchTargetKind.directory);
    });

    test('image extensions -> image', () {
      expect(kind('a/b/pic.JPG'), SearchTargetKind.image);
      expect(kind('icon.png'), SearchTargetKind.image);
      expect(kind('photo.heic'), SearchTargetKind.image);
    });

    test('video extensions -> video', () {
      expect(kind('clip.mp4'), SearchTargetKind.video);
      expect(kind('movie.MKV'), SearchTargetKind.video);
    });

    test('anything else -> other', () {
      expect(kind('notes.txt'), SearchTargetKind.other);
      expect(kind('archive.zip'), SearchTargetKind.other);
      expect(kind('no_extension'), SearchTargetKind.other);
    });
  });

  group('SearchScreen debounce / clear behaviour', () {
    MockAdapter searchAdapter() => MockAdapter(
        (o) => MockAdapter.text('{"dir":false,"path":"hit.txt"}\n'));

    FileBrowserClient clientFor(MockAdapter adapter) => FileBrowserClient(
        baseUrl: 'https://demo.example.com', adapter: adapter)
      ..adoptToken(_jwt(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600));

    Future<void> pumpScreen(WidgetTester tester, FileBrowserClient client) {
      return tester.pumpWidget(MaterialApp(
        home: SearchScreen(client: client, root: '/'),
      ));
    }

    testWidgets('clear (X) affordance tracks live text without debounce lag',
        (tester) async {
      final adapter = searchAdapter();
      await pumpScreen(tester, clientFor(adapter));

      // No text yet -> no clear button.
      expect(find.byIcon(Icons.clear), findsNothing);

      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(); // a single frame, well under the 350ms debounce.

      // Clear button appears immediately, before any debounced search runs.
      expect(find.byIcon(Icons.clear), findsOneWidget);
      expect(adapter.requests, isEmpty);

      // Tapping clear empties the field and hides the affordance synchronously.
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump();
      expect(find.byIcon(Icons.clear), findsNothing);

      // Drain any timers to avoid pending-timer failures.
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('manual submit cancels the pending debounce (no duplicate call)',
        (tester) async {
      final adapter = searchAdapter();
      await pumpScreen(tester, clientFor(adapter));

      await tester.enterText(find.byType(TextField), 'report');
      // Submit BEFORE the 350ms debounce elapses.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // Let the (now-cancelled) debounce window pass.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final searches = adapter.requests
          .where((o) => o.uri.path.contains('/search'))
          .toList();
      expect(searches.length, 1,
          reason: 'submit should fire once; the stale timer must be cancelled');
    });

    testWidgets('a too-short query never hits the server and prompts to keep typing',
        (tester) async {
      final adapter = searchAdapter();
      await pumpScreen(tester, clientFor(adapter));

      await tester.enterText(find.byType(TextField), 'ab');
      // Let the debounce fully elapse so a search WOULD have fired if allowed.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final searches = adapter.requests
          .where((o) => o.uri.path.contains('/search'))
          .toList();
      expect(searches, isEmpty,
          reason: 'quantum rejects <3 char queries; do not fire one');
      expect(find.textContaining('Keep typing'), findsOneWidget);
    });
  });
}
