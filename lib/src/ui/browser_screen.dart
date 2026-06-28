import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import '../auth/auth_controller.dart';
import '../transfers/transfer_service.dart';

/// Directory browser with download (per file) and upload (FAB) actions.
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

  Future<void> _download(FbResource item) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = _client.rawDownloadUri(
      item.path,
      algo: item.isDir ? 'zip' : null,
    );
    await _transfers.download(
      downloadUrl: url,
      token: _client.token!,
      filename: item.isDir ? '${item.name}.zip' : item.name,
    );
    messenger.showSnackBar(SnackBar(content: Text('Downloading ${item.name}…')));
  }

  Future<void> _upload() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
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
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _open(_path),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'lock') context.read<AuthController>().signOut();
              if (v == 'forget') {
                context.read<AuthController>().signOut(forget: true);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'lock',
                child: Text('Lock (${user?.username ?? ''})'),
              ),
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
              return _ErrorView(
                  message: snap.error.toString(), onRetry: () => _open(_path));
            }
            final items = snap.data?.sortedItems ?? const [];
            if (items.isEmpty) {
              return const _EmptyView();
            }
            return ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final item = items[i];
                return ListTile(
                  leading: Icon(
                    item.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                  ),
                  title: Text(item.name),
                  subtitle: item.isDir ? null : Text(_humanSize(item.size)),
                  trailing: IconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip: item.isDir ? 'Download as zip' : 'Download',
                    onPressed: () => _download(item),
                  ),
                  onTap: item.isDir ? () => _open(item.path) : () => _download(item),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _upload,
        tooltip: 'Upload here',
        child: const Icon(Icons.upload),
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

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 120),
        Center(child: Text('This folder is empty')),
      ],
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
