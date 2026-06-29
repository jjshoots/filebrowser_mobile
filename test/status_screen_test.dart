import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/ui/status_screen.dart';

import 'support/mock_adapter.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _jwt(int expEpoch) =>
    '${_b64({'alg': 'HS256'})}.${_b64({'exp': expEpoch})}.sig';

FileBrowserClient _client(MockAdapter adapter) =>
    FileBrowserClient(baseUrl: 'https://demo.example.com', adapter: adapter)
      ..adoptToken(_jwt(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600));

void main() {
  group('diskUsageAvailable (total=0 => unavailable)', () {
    test('non-directory total=0 is treated as unavailable', () {
      expect(diskUsageAvailable(FbUsage(total: 0, used: 0)), isFalse);
    });

    test('a real capacity is available', () {
      final u = FbUsage(total: 100, used: 40);
      expect(diskUsageAvailable(u), isTrue);
      // sanity: the fraction the bar binds to is well-defined and finite.
      expect(u.usedFraction, 0.4);
      expect(u.free, 60);
    });

    test('usedFraction is 0 (not NaN) when total is 0', () {
      expect(FbUsage(total: 0, used: 0).usedFraction, 0);
    });
  });

  group('tryLoadSettings (admin-only getSettings degrades gracefully)', () {
    test('a 403 from getSettings degrades to permissive defaults (no throw)',
        () async {
      final client =
          _client(MockAdapter((_) => MockAdapter.json({}, status: 403)));
      final caps = await tryLoadSettings(client);
      // getSettings swallows the admin-only 403 and yields permissive defaults.
      expect(caps, isNotNull);
      expect(caps!.signup, isFalse);
      expect(caps.name, '');
    });

    test('a network/other error collapses to null', () async {
      final client =
          _client(MockAdapter((_) => MockAdapter.json({}, status: 500)));
      expect(await tryLoadSettings(client), isNull);
    });

    test('a successful response is surfaced as caps', () async {
      final client = _client(MockAdapter((_) => MockAdapter.json({
            'auth': {
              'methods': {
                'password': {'signup': true},
              },
            },
            'frontend': {'name': 'My Files'},
            'tus': {'chunkSize': 1024, 'retryCount': 3},
          })));
      final caps = await tryLoadSettings(client);
      expect(caps, isNotNull);
      expect(caps!.name, 'My Files');
      expect(caps.signup, isTrue);
      expect(caps.tus.chunkSize, 1024);
    });
  });
}
