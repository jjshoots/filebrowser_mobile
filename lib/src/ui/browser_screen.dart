import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import '../auth/auth_controller.dart';
import '../data/preferences_store.dart';
import '../transfers/transfer_service.dart';
import 'batch_ops.dart';
import 'breadcrumbs.dart';
import 'destination_picker.dart';
import 'error_display.dart';
import 'file_details_sheet.dart';
import 'image_gallery_screen.dart';
import 'search_screen.dart';
import 'selection_controller.dart';
import 'status_screen.dart';
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
  late SortKey _sortKey;
  late bool _sortAsc;

  // Retained across rebuilds so the grid's scroll offset survives opening and
  // closing a media viewer (product item 2) and any incidental rebuild. See the
  // diagnosis note above [build].
  final ScrollController _scrollController = ScrollController();

  // --- M3 multiselect --------------------------------------------------------
  // Selection state is factored into [SelectionController] (tracked by path so
  // it survives re-sorts/rebuilds). Tap/long-press funnel through
  // [_handleTap]/[_handleLongPress] and intercept when the mode is armed.
  final SelectionController _selection = SelectionController();

  // The currently displayed (sorted) listing, captured as the listing Future
  // resolves so the contextual app bar's 'select all' and the batch actions can
  // reach the items without re-reading the snapshot.
  List<FbResource> _visibleItems = const [];

  // A choice the user opted to apply to every remaining conflict in one batch
  // ("apply to all"); reset before each move/copy run.
  ConflictChoice? _bulkConflictChoice;

  PreferencesStore get _prefs => context.read<PreferencesStore>();

  /// Re-selecting the active key flips direction (like the web column headers);
  /// a new key sorts ascending. Persists the choice so it survives app restart.
  void _applySort(SortKey key) {
    setState(() {
      if (_sortKey == key) {
        _sortAsc = !_sortAsc;
      } else {
        _sortKey = key;
        _sortAsc = true;
      }
    });
    _prefs.setSort(_sortKey, _sortAsc);
  }

  PopupMenuItem<SortKey> _sortMenuItem(SortKey key, String label) {
    final active = _sortKey == key;
    return PopupMenuItem<SortKey>(
      value: key,
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: active
                ? Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 18)
                : null,
          ),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontWeight: active ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  FileBrowserClient get _client => context.read<AuthController>().client!;
  TransferService get _transfers => context.read<TransferService>();

  @override
  void initState() {
    super.initState();
    // Seed the sort from the persisted preference so the user's last choice is
    // applied immediately on launch. context.read is allowed in initState.
    final sort = _prefs.sort;
    _sortKey = sort.key;
    _sortAsc = sort.ascending;
    _listing = _client.listDirectory(_path);
    // Rebuild the screen chrome (app bar / action bar) when selection changes.
    _selection.addListener(_onSelectionChanged);
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _open(String path) {
    // Leaving the directory abandons any in-progress selection (paths are
    // directory-scoped). A same-path refresh keeps the mode so post-action
    // cleanup can prune the set itself.
    if (path != _path) _selection.exit();
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

  // --- search ----------------------------------------------------------------

  /// Opens search scoped to the current directory and dispatches the picked hit
  /// through the browser's own flows (navigate / view / actions), so all of the
  /// viewer/action wiring stays in one place. Result paths from the server are
  /// relative to [_path]; [SearchScreen] resolves them to absolute paths.
  Future<void> _openSearch() async {
    final pick = await Navigator.of(context).push<SearchPick>(
      MaterialPageRoute(
        builder: (_) => SearchScreen(client: _client, root: _path),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick.isDir) {
      _open(pick.path);
      return;
    }
    // A file: fetch its metadata (the resources endpoint returns a file's info),
    // then route exactly like a grid tap — viewer for media, action sheet else.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await _client.listDirectory(pick.path);
      if (!mounted) return;
      if (res.isImage) {
        _openImage(res, [res]);
      } else if (res.isVideo) {
        _openVideo(res);
      } else {
        _showActions(res);
      }
    } catch (e) {
      showErrorSnackBar(messenger, 'Could not open ${p.posix.basename(pick.path)}: $e');
    }
  }

  void _openStatus() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StatusScreen(
        client: _client,
        user: context.read<AuthController>().user,
      ),
    ));
  }

  // --- item activation -------------------------------------------------------
  // Single tap/long-press funnels (the M3 selection seam): when selection mode
  // lands, intercept here to toggle selection instead of activating the item.

  void _handleTap(FbResource item, List<FbResource> all) {
    // While selecting, a tap toggles membership — even for folders (navigation
    // is suspended) — so the user can build a set without leaving the grid.
    if (_selection.active) {
      _selection.toggle(item.path);
      return;
    }
    if (item.isDir) {
      _open(item.path);
    } else if (item.isImage) {
      _openImage(item, all);
    } else if (item.isVideo) {
      _openVideo(item);
    } else {
      _showActions(item);
    }
  }

  void _openImage(FbResource item, List<FbResource> all) {
    final images = all.where((e) => e.isImage).toList();
    var index = images.indexWhere((e) => e.path == item.path);
    // When opened from search the image may not be among [all]; show it alone.
    if (index < 0) {
      images.insert(0, item);
      index = 0;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ImageGalleryScreen(
        client: _client,
        images: images,
        initialIndex: index,
      ),
    ));
  }

  void _openVideo(FbResource item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        url: _client.rawUri(item.path, inline: true),
        headers: _client.authHeaders,
        title: item.name,
        resource: item,
        client: _client,
      ),
    ));
  }

  void _handleLongPress(FbResource item, List<FbResource> all) {
    // Long-press is the gesture that *enters* multiselect (selecting the item);
    // once armed it toggles, like the OS gallery. The per-item action sheet
    // (rename / single download / delete) stays reachable by tapping a generic
    // file when NOT selecting — see [_handleTap]'s default branch.
    if (_selection.active) {
      _selection.toggle(item.path);
    } else {
      _selection.enter(item.path);
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
              subtitle: item.isDir ? null : Text(formatBytes(item.size)),
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
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Details'),
              onTap: () {
                Navigator.pop(sheetCtx);
                FileDetailsSheet.show(context, resource: item, client: _client);
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
      showErrorSnackBar(messenger, 'Rename failed: $e');
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
      showErrorSnackBar(messenger, 'Delete failed: $e');
    }
  }

  // --- batch (multiselect) actions -------------------------------------------

  /// The selected paths resolved against the visible listing, preserving the
  /// grid's display order.
  List<FbResource> _selectedResources() {
    final sel = _selection.selected;
    return _visibleItems.where((e) => sel.contains(e.path)).toList();
  }

  Future<void> _deleteSelected() async {
    final items = _selectedResources();
    if (items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${items.length} item(s)?'),
        content: const Text(
            'Selected files and folders (with their contents) will be '
            'permanently deleted. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final failures = <String>[];
    for (final item in items) {
      try {
        await _client.delete(item.path);
      } catch (e) {
        failures.add('${item.name}: $e');
      }
    }
    _selection.exit();
    _open(_path);
    if (failures.isNotEmpty) {
      showErrorSnackBar(
          messenger, 'Delete failed for ${failures.length} item(s):\n'
              '${failures.join('\n')}');
    }
  }

  /// Downloads the selection as a single server-built zip via the raw multi-file
  /// endpoint (`?files=…&algo=zip`) — one background task instead of N — which
  /// also recurses folders for free. A lone file is fetched directly (no zip).
  Future<void> _downloadSelected() async {
    final items = _selectedResources();
    if (items.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    if (items.length == 1 && !items.first.isDir) {
      _selection.exit();
      await _download(items.first);
      return;
    }
    final names = items.map((e) => e.name).toList();
    final url = _client.rawBundleDownloadUri(_path, names, algo: 'zip');
    final base = _path == '/' ? 'files' : p.posix.basename(_path);
    _selection.exit();
    await _transfers.download(
      downloadUrl: url,
      token: _client.token!,
      filename: '$base.zip',
    );
    messenger.showSnackBar(
        SnackBar(content: Text('Downloading ${names.length} item(s) as zip…')));
  }

  Future<void> _moveOrCopySelected(TransferOp op) async {
    final items = _selectedResources();
    if (items.isEmpty) return;
    final movingDirs = op == TransferOp.move
        ? items.where((e) => e.isDir).map((e) => e.path).toSet()
        : const <String>{};
    final dest = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DestinationPicker(
          client: _client,
          title: op == TransferOp.move ? 'Move to' : 'Copy to',
          confirmLabel: op == TransferOp.move ? 'Move here' : 'Copy here',
          initialPath: _path,
          canCreate: context.read<AuthController>().user?.canCreate ?? false,
          movingPaths: movingDirs,
        ),
      ),
    );
    if (dest == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _bulkConflictChoice = null;
    final result = await runTransferBatch(
      client: _client,
      op: op,
      items: items,
      destDir: dest,
      onConflict: _resolveConflict,
    );
    _selection.exit();
    _open(_path);
    final verb = op == TransferOp.move ? 'Moved' : 'Copied';
    if (result.failures.isNotEmpty) {
      showErrorSnackBar(
          messenger,
          '$verb ${result.succeeded}, skipped ${result.skipped}; '
          '${result.failures.length} failed:\n'
          '${result.failures.map((f) => '${f.item.name}: ${f.error}').join('\n')}');
    } else if (result.aborted) {
      // The user cancelled a mid-batch conflict prompt; the remainder was never
      // attempted, so spell out that it didn't complete.
      messenger.showSnackBar(SnackBar(
          content: Text('Cancelled; $verb ${result.succeeded}, '
              'skipped ${result.skipped}')));
    } else {
      messenger.showSnackBar(SnackBar(
          content: Text('$verb ${result.succeeded} item(s)'
              '${result.skipped > 0 ? ', skipped ${result.skipped}' : ''}')));
    }
  }

  /// Per-item conflict prompt for move/copy. Offers overwrite / skip / keep-both
  /// and an "apply to all" toggle that remembers the choice for the rest of the
  /// batch. Returns null to abort the remainder.
  Future<ConflictChoice?> _resolveConflict(
      FbResource item, String targetPath) async {
    if (_bulkConflictChoice != null) return _bulkConflictChoice;
    var applyAll = false;
    final choice = await showDialog<ConflictChoice>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Already exists'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"${item.name}" already exists in the destination.'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: applyAll,
                onChanged: (v) => setLocal(() => applyAll = v ?? false),
                title: const Text('Apply to all remaining'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ConflictChoice.skip),
                child: const Text('Skip')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ConflictChoice.keepBoth),
                child: const Text('Keep both')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ConflictChoice.overwrite),
                child: const Text('Overwrite')),
          ],
        ),
      ),
    );
    if (applyAll && choice != null) _bulkConflictChoice = choice;
    return choice;
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

  /// Recursively uploads a picked folder, recreating its subtree under the
  /// current directory. The server auto-creates parent dirs on upload, so we
  /// just send each file to its full relative path.
  ///
  /// NOTE: on Android 13+ scoped storage, reading a SAF-picked directory via
  /// dart:io may require all-files-access (MANAGE_EXTERNAL_STORAGE). If listing
  /// fails with a permission error on a real device, we'll need permission_handler
  /// or a SAF/content-URI directory walk. Verified path works for app-readable dirs.
  Future<void> _uploadFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return;
    final folderName = p.basename(dirPath);
    var count = 0;
    try {
      await for (final entity
          in Directory(dirPath).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: dirPath);
        final remote = p.posix.join(
            _path == '/' ? '' : _path, folderName, p.split(rel).join('/'));
        final target = remote.startsWith('/') ? remote : '/$remote';
        await _transfers.upload(
          uploadUrl: _client.uploadUri(target),
          token: _client.token!,
          localFilePath: entity.path,
        );
        count++;
      }
    } catch (e) {
      showErrorSnackBar(messenger, 'Folder upload failed: $e');
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(count == 0
          ? 'No files found in "$folderName"'
          : 'Uploading $count file(s) from "$folderName"…'),
    ));
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
      showErrorSnackBar(messenger, 'Could not create folder: $e');
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
              leading: const Icon(Icons.drive_folder_upload_outlined),
              title: const Text('Upload folder'),
              subtitle: const Text('Uploads the folder and its contents'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _uploadFolder();
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

  // Scroll-retention (product item 2): the offset is preserved because (a) the
  // directory listing Future lives in [_listing] and is only reassigned in
  // [_open] — plain rebuilds (e.g. returning from a viewer) reuse the resolved
  // snapshot rather than re-fetching — and (b) the grid uses a retained
  // [_scrollController] plus a per-path PageStorageKey, so the offset is not
  // discarded when the widget subtree rebuilds.
  @override
  Widget build(BuildContext context) {
    final user = context.read<AuthController>().user;
    final selecting = _selection.active;
    return PopScope(
      // While selecting, the system/app back gesture exits selection mode
      // instead of leaving the screen.
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selection.exit();
      },
      child: Scaffold(
        appBar: selecting
            ? _selectionAppBar(context)
            : _browseAppBar(context, user),
        body: RefreshIndicator(
          onRefresh: () async => _open(_path),
          child: FutureBuilder<FbResource>(
            future: _listing,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return CopyableErrorView(
                    message: snap.error.toString(), onRetry: () => _open(_path));
              }
              final items = snap.data?.sortedBy(_sortKey, _sortAsc) ?? const [];
              // Cache for the contextual app bar / batch actions (see field).
              _visibleItems = items;
              if (items.isEmpty) return const _EmptyView();
              return _ResourceGrid(
                // Keyed by path so each directory retains its own scroll position.
                key: PageStorageKey<String>(_path),
                items: items,
                client: _client,
                controller: _scrollController,
                selectionActive: selecting,
                selectedPaths: _selection.selected,
                onTap: (item) => _handleTap(item, items),
                onLongPress: (item) => _handleLongPress(item, items),
              );
            },
          ),
        ),
        bottomNavigationBar:
            selecting ? _selectionActionBar(context, user) : null,
        floatingActionButton: selecting
            ? null
            : FloatingActionButton(
                onPressed: _showCreateMenu,
                tooltip: 'Create',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  AppBar _browseAppBar(BuildContext context, FbUser? user) {
    return AppBar(
      title: Breadcrumbs(path: _path, onTap: _open),
      leading: _path == '/'
          ? null
          : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goUp),
      actions: [
        IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: _openSearch),
        PopupMenuButton<SortKey>(
          icon: const Icon(Icons.sort),
          tooltip: 'Sort',
          onSelected: _applySort,
          itemBuilder: (_) => [
            _sortMenuItem(SortKey.name, 'Name'),
            _sortMenuItem(SortKey.size, 'Size'),
            _sortMenuItem(SortKey.modified, 'Date modified'),
          ],
        ),
        IconButton(icon: const Icon(Icons.refresh), onPressed: () => _open(_path)),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'status') _openStatus();
            if (v == 'lock') context.read<AuthController>().signOut();
            if (v == 'forget') context.read<AuthController>().signOut(forget: true);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'status', child: Text('Status')),
            PopupMenuItem(value: 'lock', child: Text('Lock (${user?.username ?? ''})')),
            const PopupMenuItem(value: 'forget', child: Text('Sign out & forget')),
          ],
        ),
      ],
    );
  }

  /// Contextual app bar shown in selection mode: count, select-all, clear.
  AppBar _selectionAppBar(BuildContext context) {
    final total = _visibleItems.length;
    final allSelected = total > 0 && _selection.count >= total;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Exit selection',
        onPressed: _selection.exit,
      ),
      title: Text('${_selection.count} selected'),
      actions: [
        IconButton(
          tooltip: allSelected ? 'Deselect all' : 'Select all',
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          onPressed: () => allSelected
              ? _selection.clear()
              : _selection.selectAll(_visibleItems.map((e) => e.path)),
        ),
      ],
    );
  }

  /// Bottom action bar for the current selection. Rename/move/copy/delete are
  /// gated on modify permission; download is always available. Rename is a
  /// single-item op (the only way to rename a folder or media file, since their
  /// tap routes to navigation/viewer rather than the per-item sheet), so it is
  /// enabled only when exactly one item is selected.
  Widget _selectionActionBar(BuildContext context, FbUser? user) {
    final canModify = user?.canModify ?? false;
    final has = _selection.count > 0;
    final single = _selection.count == 1;
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _barAction(Icons.download_outlined, 'Download',
              has ? _downloadSelected : null),
          _barAction(Icons.drive_file_rename_outline, 'Rename',
              single && canModify ? _renameSelected : null),
          _barAction(Icons.drive_file_move_outlined, 'Move',
              has && canModify ? () => _moveOrCopySelected(TransferOp.move) : null),
          _barAction(Icons.copy_outlined, 'Copy',
              has && canModify ? () => _moveOrCopySelected(TransferOp.copy) : null),
          _barAction(Icons.delete_outline, 'Delete',
              has && canModify ? _deleteSelected : null),
        ],
      ),
    );
  }

  /// Renames the lone selected item, then leaves selection mode. Reuses the
  /// per-item [_rename] flow so folders and media (whose tile tap navigates or
  /// opens a viewer) remain renameable from the selection bar.
  Future<void> _renameSelected() async {
    final items = _selectedResources();
    if (items.length != 1) return;
    final item = items.single;
    _selection.exit();
    await _rename(item);
  }

  Widget _barAction(IconData icon, String label, VoidCallback? onPressed) {
    return Expanded(
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The directory listing as a gallery grid.
///
/// Extracted from [BrowserScreen] so future milestones can extend it cleanly:
/// M3 (multiselect) adds a `selectedPaths` set + selection chrome here, and M5
/// (IO) can surface per-tile transfer progress — all without touching the
/// screen's navigation/sort/error wiring. Tap and long-press are reported per
/// item via callbacks; the parent decides what they mean (activate vs. select).
///
/// Takes the parent's retained [controller] so scroll offset survives rebuilds
/// (product item 2).
class _ResourceGrid extends StatelessWidget {
  const _ResourceGrid({
    super.key,
    required this.items,
    required this.client,
    required this.controller,
    required this.selectionActive,
    required this.selectedPaths,
    required this.onTap,
    required this.onLongPress,
  });

  final List<FbResource> items;
  final FileBrowserClient client;
  final ScrollController controller;
  final bool selectionActive;
  final Set<String> selectedPaths;
  final ValueChanged<FbResource> onTap;
  final ValueChanged<FbResource> onLongPress;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => _GalleryTile(
        item: items[i],
        client: client,
        selectionActive: selectionActive,
        selected: selectedPaths.contains(items[i].path),
        onTap: () => onTap(items[i]),
        onLongPress: () => onLongPress(items[i]),
      ),
    );
  }
}

/// One grid cell: folder, image thumbnail, video thumbnail (+play badge), or
/// a generic file tile.
class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.item,
    required this.client,
    required this.selectionActive,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final FbResource item;
  final FileBrowserClient client;
  final bool selectionActive;
  final bool selected;
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

    final primary = Theme.of(context).colorScheme.primary;
    return Stack(
      fit: StackFit.expand,
      children: [
        InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child:
              ClipRRect(borderRadius: BorderRadius.circular(6), child: content),
        ),
        // Selected highlight: a translucent wash + border, non-interactive so
        // taps still reach the InkWell beneath.
        if (selected)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.25),
                  border: Border.all(color: primary, width: 3),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
        // Checkmark / empty-circle overlay while selecting.
        if (selectionActive)
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              decoration: const BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle),
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? primary : Colors.grey,
                size: 22,
              ),
            ),
          ),
      ],
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

