import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import 'batch_ops.dart';
import 'breadcrumbs.dart';
import 'error_display.dart';

/// Folder-tree picker used by the multiselect *move* / *copy* flow.
///
/// Browses directories only (files are listed greyed-out for context but are
/// not tappable), navigable by tapping a folder or any breadcrumb ancestor. A
/// 'New folder' action lets the user create a destination on the fly
/// ([FileBrowserClient.makeDirectory]), and 'Select this folder' confirms the
/// current directory.
///
/// When [movingPaths] is supplied (a *move*), folders that are being moved — and
/// any directory inside them — cannot be entered or selected, preventing a
/// folder from being moved into itself or a descendant
/// ([isMoveIntoSelfOrDescendant]).
///
/// Pushed via `Navigator.push<String>`: pops the chosen server path, or `null`
/// if the user backs out.
class DestinationPicker extends StatefulWidget {
  const DestinationPicker({
    super.key,
    required this.client,
    this.title = 'Choose folder',
    this.confirmLabel = 'Move here',
    this.initialPath = '/',
    this.canCreate = true,
    this.movingPaths = const <String>{},
  });

  final FileBrowserClient client;
  final String title;
  final String confirmLabel;
  final String initialPath;

  /// Whether to surface the 'New folder' action (gated on the user's create
  /// permission by the caller).
  final bool canCreate;

  /// Source folder paths of an in-flight *move* (empty for copy). Used to block
  /// self/descendant destinations.
  final Set<String> movingPaths;

  @override
  State<DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<DestinationPicker> {
  late String _path;
  late Future<FbResource> _listing;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _listing = widget.client.listDirectory(_path);
  }

  void _open(String path) {
    setState(() {
      _path = path;
      _listing = widget.client.listDirectory(path);
    });
  }

  /// True when [dir] is one of the folders being moved, or sits inside one — a
  /// destination that would move a folder into itself/a descendant.
  bool _blocked(String dir) =>
      widget.movingPaths.any((src) => isMoveIntoSelfOrDescendant(src, dir));

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final dir = p.posix.join(_path == '/' ? '' : _path, name);
    final target = dir.startsWith('/') ? dir : '/$dir';
    try {
      await widget.client.makeDirectory(target);
      _open(_path); // refresh; the new folder is now navigable
    } catch (e) {
      showErrorSnackBar(messenger, 'Could not create folder: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSelectHere = !_blocked(_path);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Breadcrumbs(path: _path, onTap: _open),
            ),
          ),
        ),
      ),
      body: FutureBuilder<FbResource>(
        future: _listing,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return CopyableErrorView(
                message: snap.error.toString(), onRetry: () => _open(_path));
          }
          final all = snap.data?.sortedItems ?? const <FbResource>[];
          final folders = all.where((e) => e.isDir).toList(growable: false);
          final fileCount = all.length - folders.length;
          if (folders.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 80),
                Center(
                  child: Text(fileCount == 0
                      ? 'No subfolders here'
                      : 'No subfolders ($fileCount file(s) hidden)'),
                ),
              ],
            );
          }
          return ListView.builder(
            itemCount: folders.length,
            itemBuilder: (_, i) {
              final f = folders[i];
              final blocked = _blocked(f.path);
              return ListTile(
                leading: Icon(Icons.folder,
                    color: blocked ? Theme.of(context).disabledColor : null),
                title: Text(f.name,
                    style: blocked
                        ? TextStyle(color: Theme.of(context).disabledColor)
                        : null),
                trailing: blocked
                    ? const Icon(Icons.block, size: 18)
                    : const Icon(Icons.chevron_right),
                onTap: blocked ? null : () => _open(f.path),
              );
            },
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (widget.canCreate)
                OutlinedButton.icon(
                  onPressed: _newFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('New folder'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: canSelectHere
                    ? () => Navigator.of(context).pop(_path)
                    : null,
                icon: const Icon(Icons.check),
                label: Text(widget.confirmLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
