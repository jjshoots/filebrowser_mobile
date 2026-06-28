import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import '../auth/auth_controller.dart';
import '../transfers/transfer_service.dart';
import 'image_gallery_screen.dart';
import 'video_player_screen.dart';

/// Gallery-style browser: a unified grid where folders are tiles and
/// images/videos show thumbnails. Tapping media opens an in-app viewer/player;
/// download/upload/rename/delete are secondary actions (FAB + long-press sheet).
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  String _path = '/';
  late Future<FbResource> _listing;

  FileBrowserClient get _client => context.read<AuthController>().client!;
  TransferService get _transfers => context.read<TransferService>();

  @override
  void initState() {
    super.initState();
    _listing = _client.listDirectory(_path);
  }

  void _open(String path) {
    setState(() {
      _path = path;
      _listing = _client.listDirectory(path);
    });
  }

  void _goUp() {
    if (_path == '/') return;
    final parent = p.dirname(_path);
    _open(parent == '.' ? '/' : parent);
  }

  // --- item activation -------------------------------------------------------

  void _onTap(FbResource item, List<FbResource> all) {
    if (item.isDir) {
      _open(item.path);
    } else if (item.isImage) {
      final images = all.where((e) => e.isImage).toList();
      final index = images.indexWhere((e) => e.path == item.path);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ImageGalleryScreen(
          client: _client,
          images: images,
          initialIndex: index < 0 ? 0 : index,
        ),
      ));
    } else if (item.isVideo) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          url: _client.rawUri(item.path, inline: true),
          headers: _client.authHeaders,
          title: item.name,
        ),
      ));
    } else {
      _showActions(item);
    }
  }

  // --- secondary actions -----------------------------------------------------

  Future<void> _showActions(FbResource item) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(item.isDir ? Icons.folder : Icons.insert_drive_file),
              title: Text(item.name, overflow: TextOverflow.ellipsis),
              subtitle: item.isDir ? null : Text(_humanSize(item.size)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(item.isDir ? 'Download as zip' : 'Download'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _download(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _rename(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _delete(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _download(FbResource item) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = _client.rawDownloadUri(item.path, algo: item.isDir ? 'zip' : null);
    await _transfers.download(
      downloadUrl: url,
      token: _client.token!,
      filename: item.isDir ? '${item.name}.zip' : item.name,
    );
    messenger.showSnackBar(SnackBar(content: Text('Downloading ${item.name}…')));
  }

  Future<void> _rename(FbResource item) async {
    final controller = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == item.name) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final parent = p.posix.dirname(item.path);
    final dest = p.posix.join(parent == '.' ? '/' : parent, newName);
    try {
      await _client.rename(item.path, dest);
      _open(_path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Rename failed: $e')));
    }
  }

  Future<void> _delete(FbResource item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${item.name}?'),
        content: Text(item.isDir
            ? 'This deletes the folder and everything in it.'
            : 'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _client.delete(item.path);
      _open(_path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _upload() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null) return;
    for (final f in result.files) {
      if (f.path == null) continue;
      final dest = p.posix.join(_path == '/' ? '' : _path, f.name);
      final target = dest.startsWith('/') ? dest : '/$dest';
      await _transfers.upload(
        uploadUrl: _client.uploadUri(target),
        token: _client.token!,
        localFilePath: f.path!,
      );
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Uploading ${result.files.length} file(s)…')),
    );
  }

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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
      await _client.makeDirectory(target);
      _open(_path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create folder: $e')));
    }
  }

  Future<void> _showCreateMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload files'),
              subtitle: const Text('Select one or more files'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _upload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _newFolder();
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final user = context.read<AuthController>().user;
    return Scaffold(
      appBar: AppBar(
        title: Text(_path == '/' ? 'Files' : p.basename(_path)),
        leading: _path == '/'
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goUp),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _open(_path)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'lock') context.read<AuthController>().signOut();
              if (v == 'forget') context.read<AuthController>().signOut(forget: true);
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'lock', child: Text('Lock (${user?.username ?? ''})')),
              const PopupMenuItem(value: 'forget', child: Text('Sign out & forget')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _open(_path),
        child: FutureBuilder<FbResource>(
          future: _listing,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _ErrorView(message: snap.error.toString(), onRetry: () => _open(_path));
            }
            final items = snap.data?.sortedItems ?? const [];
            if (items.isEmpty) return const _EmptyView();
            return GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: items.length,
              itemBuilder: (_, i) => _GalleryTile(
                item: items[i],
                client: _client,
                onTap: () => _onTap(items[i], items),
                onLongPress: () => _showActions(items[i]),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateMenu,
        tooltip: 'Create',
        child: const Icon(Icons.add),
      ),
    );
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double size = bytes / 1024;
    int i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${units[i]}';
  }
}

/// One grid cell: folder, image thumbnail, video thumbnail (+play badge), or
/// a generic file tile.
class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.item,
    required this.client,
    required this.onTap,
    required this.onLongPress,
  });

  final FbResource item;
  final FileBrowserClient client;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget content;
    if (item.isDir) {
      content = _labelled(surface, Icons.folder, item.name);
    } else if (item.isImage || item.isVideo) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: client.previewUri(item.path).toString(),
            httpHeaders: client.authHeaders,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(color: surface),
            errorWidget: (_, __, ___) => Container(
              color: surface,
              child: Icon(item.isVideo ? Icons.movie : Icons.broken_image,
                  color: Colors.grey),
            ),
          ),
          if (item.isVideo)
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 40),
            ),
        ],
      );
    } else {
      content = _labelled(surface, _iconForType(item), item.name);
    }

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(borderRadius: BorderRadius.circular(6), child: content),
    );
  }

  Widget _labelled(Color bg, IconData icon, String name) => Container(
        color: bg,
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      );

  IconData _iconForType(FbResource item) {
    switch (item.type) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'text':
      case 'textImmutable':
        return Icons.description;
      case 'audio':
        return Icons.audiotrack;
      default:
        return Icons.insert_drive_file;
    }
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [SizedBox(height: 120), Center(child: Text('This folder is empty'))],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
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
        Center(child: FilledButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}
