import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/ui/share_dialog.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _makeJwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch, 'user': {'username': 'u', 'perm': {'create': true, 'modify': true}}})}.sig';

void main() {
  final item = FbResource(
    path: '/docs/a.txt',
    name: 'a.txt',
    size: 1,
    isDir: false,
  );

  (FileBrowserClient, MockAdapter) makeClient(
    ResponseBody Function(RequestOptions) handler,
  ) {
    final adapter = MockAdapter(handler);
    final client = FileBrowserClient(baseUrl: 'https://demo.example.com', adapter: adapter)
      ..adoptToken(_makeJwt(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600));
    return (client, adapter);
  }

  // Pumps a button that opens the create-share dialog for [item].
  Future<void> pumpHost(WidgetTester tester, FileBrowserClient client) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () =>
                showCreateShareDialog(context, client: client, item: item),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('blocks create with a timed unit but a non-positive amount',
      (tester) async {
    var posted = false;
    final (client, _) = makeClient((opts) {
      posted = true;
      return MockAdapter.json({'hash': 'x', 'path': item.path, 'expire': 0});
    });

    await pumpHost(tester, client);

    // Switch the expiry unit to a timed one (Days).
    await tester.tap(find.text('Never'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Days').last);
    await tester.pumpAndSettle();

    // Clear the amount, then try to create.
    await tester.enterText(find.byType(TextField).last, '');
    await tester.tap(find.text('Create link'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a positive number'), findsOneWidget);
    // Dialog stays open and no share request was made.
    expect(find.text('Create link'), findsOneWidget);
    expect(posted, isFalse);
  });

  testWidgets('creates a never-expiring share when unit is Never',
      (tester) async {
    Map<String, dynamic>? sentBody;
    final (client, _) = makeClient((opts) {
      sentBody = jsonDecode(opts.data as String) as Map<String, dynamic>;
      return MockAdapter.json({'hash': 'abc', 'path': item.path, 'expire': 0});
    });

    await pumpHost(tester, client);

    // Default unit is Never -> no amount field, create immediately.
    await tester.tap(find.text('Create link'));
    await tester.pumpAndSettle();

    expect(sentBody, isNotNull);
    expect(sentBody!['expires'], '');
    expect(sentBody!['unit'], '');
    // Result dialog shows the public link.
    expect(find.textContaining('/share/abc'), findsOneWidget);
  });
}
