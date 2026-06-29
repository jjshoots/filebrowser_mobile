import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';

/// Zero-pads to two digits.
String _pad2(int n) => n.toString().padLeft(2, '0');

/// Humanises a modified timestamp to `yyyy-MM-dd HH:mm`, or `Unknown` when
/// absent. PURE (no zone conversion here — callers pass an already-local
/// `DateTime`) so it is unit-testable. See `file_details_test.dart`.
String formatModified(DateTime? dt) {
  if (dt == null) return 'Unknown';
  return '${dt.year}-${_pad2(dt.month)}-${_pad2(dt.day)} '
      '${_pad2(dt.hour)}:${_pad2(dt.minute)}';
}

/// Android-gallery-style details bottom sheet for a single [FbResource].
///
/// Shows name, full server path (copyable), size, modified time, and type. The
/// sha256 checksum is computed ONLY when the user taps the button — auto-fetching
/// would force the server to hash the whole file. Reachable from the image
/// viewer, the video player, and the per-item action sheet.
class FileDetailsSheet extends StatefulWidget {
  const FileDetailsSheet({
    super.key,
    required this.resource,
    required this.client,
  });

  final FbResource resource;
  final FileBrowserClient client;

  /// Presents the sheet as a modal bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required FbResource resource,
    required FileBrowserClient client,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FileDetailsSheet(resource: resource, client: client),
    );
  }

  @override
  State<FileDetailsSheet> createState() => _FileDetailsSheetState();
}

class _FileDetailsSheetState extends State<FileDetailsSheet> {
  String? _checksum;
  String? _checksumError;
  bool _computing = false;

  Future<void> _computeChecksum() async {
    setState(() {
      _computing = true;
      _checksumError = null;
    });
    try {
      final sum = await widget.client.checksum(widget.resource.path);
      if (!mounted) return;
      setState(() {
        _computing = false;
        _checksum = sum.isEmpty ? '(empty)' : sum;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _computing = false;
        _checksumError = e.toString();
      });
    }
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
          content: Text('Copied'), duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.resource;
    final ext = (r.extension ?? '').replaceAll('.', '');
    final typeLabel = [
      if ((r.type ?? '').isNotEmpty) r.type,
      if (ext.isNotEmpty) '.$ext',
    ].whereType<String>().join('  ·  ');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(r.isDir ? Icons.folder : Icons.insert_drive_file, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(r.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _DetailRow(
              label: 'Path',
              value: r.path,
              onCopy: () => _copy(r.path),
            ),
            _DetailRow(
              label: 'Size',
              value: r.isDir ? '—' : formatBytes(r.size),
            ),
            _DetailRow(
              label: 'Modified',
              value: formatModified(r.modifiedAt?.toLocal()),
            ),
            if (typeLabel.isNotEmpty)
              _DetailRow(label: 'Type', value: typeLabel),
            if (!r.isDir) ...[
              const Divider(height: 28),
              _checksumSection(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _checksumSection() {
    if (_checksum != null) {
      return _DetailRow(
        label: 'sha256',
        value: _checksum!,
        monospace: true,
        onCopy: () => _copy(_checksum!),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _computing ? null : _computeChecksum,
          icon: _computing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.tag, size: 18),
          label: Text(_computing
              ? 'Computing…'
              : 'Compute checksum (sha256)'),
        ),
        if (_checksumError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Checksum failed: $_checksumError',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
  }
}

/// A labelled detail line with an optional trailing copy button.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.onCopy,
    this.monospace = false,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
                  : theme.textTheme.bodyMedium,
            ),
          ),
          if (onCopy != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy',
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }
}
