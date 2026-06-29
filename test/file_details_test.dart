import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/ui/file_details_sheet.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _jwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch, 'user': {'username': 'u', 'perm': {'create': true, 'modify': true}}})}.sig';

void main() {
  group('formatModified', () {
    test('formats to yyyy-MM-dd HH:mm with zero padding', () {
      expect(formatModified(DateTime(2026, 6, 29, 14, 3)), '2026-06-29 14:03');
      expect(formatModified(DateTime(2024, 1, 5, 9, 7)), '2024-01-05 09:07');
    });

    test('null timestamp -> Unknown', () {
      expect(formatModified(null), 'Unknown');
    });
  });

  group('size formatting (formatBytes via details)', () {
    test('matches the shared human-readable formatter', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  testWidgets('checksum is fetched ONLY when the button is pressed',
      (tester) async {
    var checksumCalls = 0;
    final adapter = MockAdapter((o) {
      if (o.uri.queryParameters.containsKey('checksum')) {
        checksumCalls++;
        return MockAdapter.json({
          'path': '/docs/report.pdf',
          'checksums': {'sha256': 'cafebabe'},
        });
      }
      return MockAdapter.json({});
    });
    final client =
        FileBrowserClient(baseUrl: 'https://demo.example.com', adapter: adapter)
          ..adoptToken(_jwt(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600));

    final resource = FbResource(
      path: '/docs/report.pdf',
      name: 'report.pdf',
      size: 2048,
      isDir: false,
      modified: '2026-06-29T14:03:00Z',
      type: 'pdf',
      extension: '.pdf',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDetailsSheet(resource: resource, client: client),
      ),
    ));

    // Nothing computed yet — the server must not be asked to hash the file.
    expect(checksumCalls, 0);
    expect(find.text('cafebabe'), findsNothing);
    expect(find.text('Compute checksum (sha256)'), findsOneWidget);

    await tester.tap(find.text('Compute checksum (sha256)'));
    await tester.pumpAndSettle();

    expect(checksumCalls, 1);
    expect(find.text('cafebabe'), findsOneWidget);
    // Verify it really was the checksum endpoint that was hit.
    final req = adapter.requests
        .firstWhere((r) => r.uri.queryParameters.containsKey('checksum'));
    expect(req.uri.queryParameters['checksum'], 'sha256');
    expect(req.uri.path, '/api/resources');
    expect(req.uri.queryParameters['path'], '/docs/report.pdf');
    expect(req.method, 'GET');
  });

  testWidgets('directories show no checksum affordance', (tester) async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client =
        FileBrowserClient(baseUrl: 'https://demo.example.com', adapter: adapter)
          ..adoptToken(_jwt(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600));
    final dir = FbResource(
        path: '/docs', name: 'docs', size: 0, isDir: true);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileDetailsSheet(resource: dir, client: client)),
    ));

    expect(find.text('Compute checksum (sha256)'), findsNothing);
    // No request should be issued merely by showing details.
    expect(adapter.requests, isEmpty);
  });
}
