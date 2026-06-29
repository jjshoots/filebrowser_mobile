import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/auth/auth_controller.dart';
import 'package:filebrowser_mobile/src/data/preferences_store.dart';
import 'package:filebrowser_mobile/src/transfers/transfer_service.dart';
import 'package:filebrowser_mobile/src/ui/browser_screen.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'support/mock_adapter.dart';

/// AuthController test double exposing a canned client/user without touching the
/// network or secure storage.
class _FakeAuth extends AuthController {
  _FakeAuth(this._client, this._user, PreferencesStore prefs)
      : super(prefs: prefs);
  final FileBrowserClient _client;
  final FbUser _user;
  @override
  FileBrowserClient? get client => _client;
  @override
  FbUser? get user => _user;
}

/// Root listing with two plain files of differing size/name so sort order is
/// observable (a.txt is smaller and alphabetically first; b.txt is larger).
ResponseBody _listingHandler(RequestOptions o) => MockAdapter.json({
      'path': '/',
      'name': '/',
      'size': 0,
      'isDir': true,
      'items': [
        {'path': '/a.txt', 'name': 'a.txt', 'size': 10, 'isDir': false},
        {'path': '/b.txt', 'name': 'b.txt', 'size': 30, 'isDir': false},
      ],
    });

Widget _harness(PreferencesStore prefs) {
  final client = FileBrowserClient(
    baseUrl: 'https://demo.example.com',
    adapter: MockAdapter(_listingHandler),
  )..adoptToken('tok');
  final auth = _FakeAuth(
    client,
    FbUser(username: 'u', canCreate: true, canModify: true),
    prefs,
  );
  return MultiProvider(
    providers: [
      Provider<PreferencesStore>.value(value: prefs),
      // Untracked service (no init() -> no platform channels) just satisfies the
      // app bar's transfers badge lookup.
      Provider<TransferService>(create: (_) => TransferService()),
      ChangeNotifierProvider<AuthController>.value(value: auth),
    ],
    child: const MaterialApp(home: BrowserScreen()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Stub the share plugin so BrowserScreen.initState's intake is inert.
    ReceiveSharingIntent.setMockValues(
        initialMedia: const [], mediaStream: const Stream.empty());
  });

  testWidgets('changing sort persists the choice via PreferencesStore',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.create();

    await tester.pumpWidget(_harness(prefs));
    await tester.pumpAndSettle();

    // Default is name/ascending.
    expect(prefs.sort, (key: SortKey.name, ascending: true));

    // Open the sort menu and pick "Size".
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size'));
    await tester.pumpAndSettle();

    // Persisted immediately (first pick of a new key => ascending).
    expect(prefs.sort, (key: SortKey.size, ascending: true));

    // A fresh store reads the same persisted value (survives restart).
    final reopened = await PreferencesStore.create();
    expect(reopened.sort, (key: SortKey.size, ascending: true));
  });

  testWidgets('initial sort is seeded from PreferencesStore', (tester) async {
    // Persisted: sort by size, descending => largest (b.txt) should come first.
    SharedPreferences.setMockInitialValues({
      'pref_sort_key': 'size',
      'pref_sort_asc': false,
    });
    final prefs = await PreferencesStore.create();

    await tester.pumpWidget(_harness(prefs));
    await tester.pumpAndSettle();

    final bPos = tester.getTopLeft(find.text('b.txt'));
    final aPos = tester.getTopLeft(find.text('a.txt'));
    // Same row (3-column grid); b precedes a horizontally under size-desc.
    expect(bPos.dx, lessThan(aPos.dx));
  });
}
