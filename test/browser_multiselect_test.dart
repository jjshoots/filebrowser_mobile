import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/auth/auth_controller.dart';
import 'package:filebrowser_mobile/src/data/preferences_store.dart';
import 'package:filebrowser_mobile/src/ui/browser_screen.dart';

import 'support/mock_adapter.dart';

class _FakeAuth extends AuthController {
  _FakeAuth(this._client, this._user);
  final FileBrowserClient _client;
  final FbUser _user;
  @override
  FileBrowserClient? get client => _client;
  @override
  FbUser? get user => _user;
}

ResponseBody _listing(RequestOptions _) => MockAdapter.json({
      'path': '/',
      'name': '/',
      'size': 0,
      'isDir': true,
      'items': [
        {'path': '/a.txt', 'name': 'a.txt', 'size': 10, 'isDir': false},
        {'path': '/b.txt', 'name': 'b.txt', 'size': 30, 'isDir': false},
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds the screen and returns the adapter so tests can count DELETEs.
  Future<MockAdapter> pumpBrowser(WidgetTester tester,
      {bool canModify = true}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.create();
    final adapter = MockAdapter((o) {
      if (o.method == 'DELETE') return MockAdapter.text('');
      return _listing(o);
    });
    final client = FileBrowserClient(
        baseUrl: 'https://demo.example.com', adapter: adapter)
      ..adoptToken('tok');
    final auth = _FakeAuth(
        client, FbUser(username: 'u', canCreate: true, canModify: canModify));
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<PreferencesStore>.value(value: prefs),
        ChangeNotifierProvider<AuthController>.value(value: auth),
      ],
      child: const MaterialApp(home: BrowserScreen()),
    ));
    await tester.pumpAndSettle();
    return adapter;
  }

  testWidgets('long-press enters selection mode; close exits it',
      (tester) async {
    await pumpBrowser(tester);

    // Normal mode: FAB present, no contextual title.
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('1 selected'), findsNothing);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    // Contextual app bar + bottom action bar appear; FAB hidden.
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.text('Delete'), findsOneWidget); // bottom bar label

    // Close exits selection mode.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('select-all then batch delete calls the client once per item',
      (tester) async {
    final adapter = await pumpBrowser(tester);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // Select all -> both items.
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    // Delete -> confirm.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 item(s)?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    final deletes = adapter.requests.where((r) => r.method == 'DELETE');
    expect(deletes.length, 2);
    // Selection mode is dismissed after the batch completes.
    expect(find.text('2 selected'), findsNothing);
  });

  testWidgets('rename action renames the single selected item via PATCH',
      (tester) async {
    final adapter = await pumpBrowser(tester);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // Rename is offered (and enabled) for a single selection.
    await tester.tap(find.byIcon(Icons.drive_file_rename_outline));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsWidgets); // dialog title + button

    await tester.enterText(find.byType(TextField), 'renamed.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    final patches = adapter.requests.where((r) => r.method == 'PATCH').toList();
    expect(patches.length, 1);
    expect(patches.single.uri.query, contains('action=rename'));
    // Selection mode is dismissed once rename runs.
    expect(find.text('1 selected'), findsNothing);
  });

  testWidgets('rename is disabled when multiple items are selected',
      (tester) async {
    await pumpBrowser(tester);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    // Tapping Rename with >1 selected is inert (no dialog).
    await tester.tap(find.byIcon(Icons.drive_file_rename_outline));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, 'Rename'), findsNothing);
  });

  testWidgets('delete is disabled without modify permission', (tester) async {
    await pumpBrowser(tester, canModify: false);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // The Delete action is present but inert (no confirm dialog appears).
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 item(s)?'), findsNothing);
  });
}
