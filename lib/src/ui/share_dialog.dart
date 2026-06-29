import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import '../api/share_link.dart';
import 'error_display.dart';

/// Opens the create-share flow for [item]: an options dialog (optional password,
/// optional expiry) that, on confirm, calls [FileBrowserClient.createShare] and
/// then shows the resulting public link (copyable + system share-sheet).
///
/// Returns true when a share was created (so callers can refresh a list).
Future<bool> showCreateShareDialog(
  BuildContext context, {
  required FileBrowserClient client,
  required FbResource item,
}) async {
  final options = await showDialog<_ShareOptions>(
    context: context,
    builder: (_) => _ShareOptionsDialog(name: item.name),
  );
  if (options == null || !context.mounted) return false;

  final messenger = ScaffoldMessenger.of(context);
  final expiry = shareExpiryParams(options.amount, options.unit);
  FbShare share;
  try {
    share = await client.createShare(
      item.path,
      password: options.password.isEmpty ? null : options.password,
      expires: expiry.expires,
      unit: expiry.unit,
    );
  } catch (e) {
    showErrorSnackBar(messenger, 'Could not create share: $e');
    return false;
  }
  if (!context.mounted) return true;

  await showShareResultDialog(context, baseUrl: client.baseUrl, share: share);
  return true;
}

/// Shows the public link for an existing/just-created [share]: the URL, a Copy
/// button (Clipboard) and a system share-sheet, plus password/expiry status.
/// Extracted so the manage-shares screen can reuse it.
Future<void> showShareResultDialog(
  BuildContext context, {
  required String baseUrl,
  required FbShare share,
}) {
  final url = publicShareUrl(baseUrl, share.hash);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Share link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(url, style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(share.hasPassword ? Icons.lock : Icons.lock_open,
                  size: 16, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(share.hasPassword
                  ? 'Password protected'
                  : 'No password'),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.schedule,
                  size: 16, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(child: Text(humanizeShareExpiry(share))),
            ],
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.share_outlined, size: 18),
          label: const Text('Share'),
          onPressed: () => Share.share(url),
        ),
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(
                  content: Text('Link copied'),
                  duration: Duration(seconds: 2)),
            );
          },
        ),
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
      ],
    ),
  );
}

/// User's create-share choices (password + expiry amount/unit).
class _ShareOptions {
  const _ShareOptions(this.password, this.amount, this.unit);
  final String password;
  final int amount;
  final ShareExpiryUnit unit;
}

class _ShareOptionsDialog extends StatefulWidget {
  const _ShareOptionsDialog({required this.name});
  final String name;

  @override
  State<_ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<_ShareOptionsDialog> {
  final _password = TextEditingController();
  final _amount = TextEditingController(text: '7');
  ShareExpiryUnit _unit = ShareExpiryUnit.never;
  bool _obscure = true;
  String? _amountError;

  @override
  void dispose() {
    _password.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timed = _unit != ShareExpiryUnit.never;
    return AlertDialog(
      title: const Text('Share link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Password (optional)',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (timed) ...[
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: _amount,
                    keyboardType: TextInputType.number,
                    onChanged: (_) {
                      if (_amountError != null) {
                        setState(() => _amountError = null);
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'Expires',
                      errorText: _amountError,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: DropdownButtonFormField<ShareExpiryUnit>(
                  initialValue: _unit,
                  decoration: const InputDecoration(labelText: 'Expiry'),
                  items: [
                    for (final u in ShareExpiryUnit.values)
                      DropdownMenuItem(value: u, child: Text(u.label)),
                  ],
                  onChanged: (u) =>
                      setState(() => _unit = u ?? ShareExpiryUnit.never),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final amount = int.tryParse(_amount.text.trim()) ?? 0;
            if (timed && amount <= 0) {
              setState(() => _amountError = 'Enter a positive number');
              return;
            }
            Navigator.pop(
              context,
              _ShareOptions(_password.text, amount, _unit),
            );
          },
          child: const Text('Create link'),
        ),
      ],
    );
  }
}
