import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared, copyable error presentation (product item 16: every error surface
/// must be copyable). No external dependency — copying uses
/// `flutter/services` [Clipboard].
///
/// Two entry points back the same contract:
///  * [errorSnackBar] / [showErrorSnackBar] for transient failures (rename,
///    delete, upload, …), each carrying a `COPY` action.
///  * [CopyableErrorView] for the full-screen listing-error state.

/// Copies [message] to the clipboard and (when a [messenger] is supplied)
/// confirms with a brief snackbar. Single place so the copy UX is identical
/// everywhere.
void copyErrorToClipboard(String message, [ScaffoldMessengerState? messenger]) {
  Clipboard.setData(ClipboardData(text: message));
  messenger?.showSnackBar(
    const SnackBar(content: Text('Error copied'), duration: Duration(seconds: 2)),
  );
}

/// Builds the standard error [SnackBar]: the full error text plus a `COPY`
/// action that puts that exact text on the clipboard. Pure builder so it can be
/// unit-tested without a live [ScaffoldMessenger].
SnackBar errorSnackBar(String message) {
  return SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 6),
    action: SnackBarAction(
      label: 'COPY',
      onPressed: () => copyErrorToClipboard(message),
    ),
  );
}

/// Shows [errorSnackBar] on [messenger], replacing any in-flight snackbar so the
/// latest failure (and its COPY action) is the one on screen. Capture the
/// `ScaffoldMessengerState` before any `await` and pass it here.
void showErrorSnackBar(ScaffoldMessengerState messenger, String message) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(errorSnackBar(message));
}

/// Full-screen error state for the directory listing: the message, a `Copy`
/// button (Clipboard), and a `Retry` action. Scrollable so it composes with
/// `RefreshIndicator` (pull-to-retry).
class CopyableErrorView extends StatelessWidget {
  const CopyableErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 100),
        const Center(child: Icon(Icons.error_outline, size: 48)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(message, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () =>
                  copyErrorToClipboard(message, ScaffoldMessenger.of(context)),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ],
    );
  }
}
