import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/ui/error_display.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('errorSnackBar', () {
    test('carries the full message and a COPY action', () {
      const msg = 'Rename failed: Exception: boom';
      final snack = errorSnackBar(msg);
      expect(snack.content, isA<Text>());
      expect((snack.content as Text).data, msg);
      expect(snack.action, isNotNull);
      expect(snack.action!.label, 'COPY');
    });
  });

  group('showErrorSnackBar', () {
    testWidgets('shows the snackbar with a COPY action', (tester) async {
      late ScaffoldMessengerState messenger;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              messenger = ScaffoldMessenger.of(context);
              return const SizedBox();
            }),
          ),
        ),
      );

      showErrorSnackBar(messenger, 'Delete failed: nope');
      await tester.pump(); // start the snackbar animation

      expect(find.text('Delete failed: nope'), findsOneWidget);
      expect(find.text('COPY'), findsOneWidget);
    });

    testWidgets('COPY action writes the full error to the clipboard',
        (tester) async {
      // Intercept the clipboard platform channel to capture what gets copied.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );

      late ScaffoldMessengerState messenger;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              messenger = ScaffoldMessenger.of(context);
              return const SizedBox();
            }),
          ),
        ),
      );

      showErrorSnackBar(messenger, 'Upload failed: disk full');
      await tester.pumpAndSettle(); // let the snackbar finish animating in
      await tester.tap(find.text('COPY'));
      await tester.pump();

      expect(copied, 'Upload failed: disk full');

      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  });

  group('CopyableErrorView', () {
    testWidgets('renders the message with Copy and Retry actions',
        (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CopyableErrorView(
              message: 'Boom: something broke',
              onRetry: () => retried = true,
            ),
          ),
        ),
      );

      expect(find.text('Boom: something broke'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Copy'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      expect(retried, isTrue);
    });
  });
}
