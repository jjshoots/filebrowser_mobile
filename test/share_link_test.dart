import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/api/share_link.dart';
import 'package:filebrowser_mobile/src/ui/shares_screen.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
String _jwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch})}.sig';
int get _nowS => DateTime.now().millisecondsSinceEpoch ~/ 1000;

FbShare _share({
  String hash = 'h',
  String path = '/p',
  int expire = 0,
  bool hasPassword = false,
}) =>
    FbShare(
        hash: hash, path: path, expire: expire, hasPassword: hasPassword);

void main() {
  group('publicShareUrl (the user-facing SPA link)', () {
    test('builds <base>/public/share/<hash>', () {
      expect(publicShareUrl('https://demo.example.com', 'aB_9-x'),
          'https://demo.example.com/public/share/aB_9-x');
    });

    test('tolerates one or several trailing slashes on the base', () {
      expect(publicShareUrl('https://demo.example.com/', 'h'),
          'https://demo.example.com/public/share/h');
      expect(publicShareUrl('https://demo.example.com///', 'h'),
          'https://demo.example.com/public/share/h');
    });

    test('keeps a sub-path base (reverse-proxied install) intact', () {
      expect(publicShareUrl('https://host/fb/', 'h'),
          'https://host/fb/public/share/h');
    });
  });

  group('shareExpiryParams (dialog selection -> server {expires, unit})', () {
    test('hours and days pass straight through', () {
      expect(shareExpiryParams(3, ShareExpiryUnit.hours),
          (expires: '3', unit: 'hours'));
      expect(shareExpiryParams(5, ShareExpiryUnit.days),
          (expires: '5', unit: 'days'));
    });

    test('weeks/months fold into days (server lacks those units)', () {
      expect(shareExpiryParams(2, ShareExpiryUnit.weeks),
          (expires: '14', unit: 'days'));
      expect(shareExpiryParams(3, ShareExpiryUnit.months),
          (expires: '90', unit: 'days'));
    });

    test('never and non-positive amounts yield no expiry', () {
      expect(shareExpiryParams(5, ShareExpiryUnit.never),
          (expires: null, unit: null));
      expect(shareExpiryParams(0, ShareExpiryUnit.days),
          (expires: null, unit: null));
      expect(shareExpiryParams(-3, ShareExpiryUnit.hours),
          (expires: null, unit: null));
    });
  });

  group('humanizeShareExpiry + isExpired', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    int at(Duration d) => (now.add(d).millisecondsSinceEpoch ~/ 1000);

    test('expire 0 never expires and is not expired', () {
      final s = _share(expire: 0);
      expect(s.isExpired, isFalse);
      expect(humanizeShareExpiry(s, now: now), 'Never expires');
    });

    test('a past expiry reads Expired and isExpired is true', () {
      final s = _share(expire: _nowS - 60);
      expect(s.isExpired, isTrue);
      expect(humanizeShareExpiry(s), 'Expired');
    });

    test('future expiries use the coarsest non-zero unit', () {
      expect(humanizeShareExpiry(_share(expire: at(const Duration(days: 14))),
          now: now), 'Expires in 2 weeks');
      expect(humanizeShareExpiry(_share(expire: at(const Duration(days: 1))),
          now: now), 'Expires in 1 day');
      expect(humanizeShareExpiry(_share(expire: at(const Duration(hours: 5))),
          now: now), 'Expires in 5 hours');
      expect(humanizeShareExpiry(_share(expire: at(const Duration(minutes: 1))),
          now: now), 'Expires in 1 minute');
      expect(humanizeShareExpiry(_share(expire: at(const Duration(seconds: 30))),
          now: now), 'Expires in less than a minute');
    });
  });

  group('createShare request shaping (mock adapter)', () {
    FileBrowserClient client(MockAdapter a) =>
        FileBrowserClient(baseUrl: 'https://demo.example.com', adapter: a)
          ..adoptToken(_jwt(_nowS + 3600));

    test('a weeks selection is sent as the day-equivalent {expires, unit}',
        () async {
      final adapter = MockAdapter((_) => MockAdapter.json({
            'hash': 'h',
            'path': '/photos/a.jpg',
            'expire': 0,
            'hasPassword': true,
          }));
      final c = client(adapter);
      final e = shareExpiryParams(2, ShareExpiryUnit.weeks);
      await c.createShare('/photos/a.jpg',
          password: 'secret', expires: e.expires, unit: e.unit);
      final req = adapter.requests.last;
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/share');
      final body = jsonDecode(req.data as String) as Map<String, dynamic>;
      expect(body, {
        'path': '/photos/a.jpg',
        'password': 'secret',
        'expires': '14',
        'unit': 'days',
      });
    });

    test('a never selection sends empty expires/unit', () async {
      final adapter = MockAdapter((_) => MockAdapter.json(
          {'hash': 'h', 'path': '/p', 'expire': 0, 'hasPassword': false}));
      final c = client(adapter);
      final e = shareExpiryParams(7, ShareExpiryUnit.never);
      await c.createShare('/p', expires: e.expires, unit: e.unit);
      final body =
          jsonDecode(adapter.requests.last.data as String) as Map<String, dynamic>;
      expect(body, {'path': '/p', 'password': '', 'expires': '', 'unit': ''});
    });
  });

  group('SharesScreen parse -> render mapping', () {
    FileBrowserClient client(MockAdapter a) =>
        FileBrowserClient(baseUrl: 'https://demo.example.com', adapter: a)
          ..adoptToken(_jwt(_nowS + 3600));

    testWidgets('renders a row per share with path, expiry and public link',
        (tester) async {
      final adapter = MockAdapter((_) => MockAdapter.json([
            {
              'hash': 'aaa',
              'path': '/photos/trip.jpg',
              'expire': 0,
              'hasPassword': true,
            },
            {
              'hash': 'bbb',
              'path': '/old.zip',
              'expire': _nowS - 60, // expired
              'hasPassword': false,
            },
          ]));
      await tester.pumpWidget(
          MaterialApp(home: SharesScreen(client: client(adapter))));
      await tester.pumpAndSettle();

      expect(find.text('/photos/trip.jpg'), findsOneWidget);
      expect(find.text('/old.zip'), findsOneWidget);
      expect(find.text('Never expires'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      // The public links are rendered (built from baseUrl + /public/share/<hash>).
      expect(
          find.text('https://demo.example.com/public/share/aaa'), findsOneWidget);
      expect(
          find.text('https://demo.example.com/public/share/bbb'), findsOneWidget);
      // Password-protected share shows a lock leading icon.
      expect(find.byIcon(Icons.lock), findsOneWidget);
    });

    testWidgets('empty list shows the empty state', (tester) async {
      final adapter = MockAdapter((_) => MockAdapter.json([]));
      await tester.pumpWidget(
          MaterialApp(home: SharesScreen(client: client(adapter))));
      await tester.pumpAndSettle();
      expect(find.text('No shared links yet'), findsOneWidget);
    });

    testWidgets('an error shows the copyable error view with retry',
        (tester) async {
      final adapter = MockAdapter((_) => MockAdapter.json({}, status: 500));
      await tester.pumpWidget(
          MaterialApp(home: SharesScreen(client: client(adapter))));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });
  });
}
