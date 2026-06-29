import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import '../auth/auth_controller.dart';
import '../data/preferences_store.dart';
import '../transfers/transfer_record.dart';
import '../transfers/transfer_service.dart';
import 'batch_ops.dart';
import 'breadcrumbs.dart';
import 'destination_picker.dart';
import 'error_display.dart';
import 'file_details_sheet.dart';
import 'image_gallery_screen.dart';
import 'search_screen.dart';
import 'selection_controller.dart';
import 'share_dialog.dart';
import 'shares_screen.dart';
import 'status_screen.dart';
import 'transfers_screen.dart';
import 'upload_conflict.dart';
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

  // --- multiselect -----------------------------------------------------------
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

  // Inbound share (SEND / SEND_MULTIPLE) plumbing: a subscription for files
  // shared while the app is alive, plus a guard so two share events can't drive
  // overlapping destination pickers/upload runs at once.
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  bool _handlingShare = false;

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
    _initShareIntake();
  }

  /// Wires inbound share-into-app: the one-shot intent that launched/relaunched
  /// the app, plus the stream of shares received while it is already running.
  /// Each batch routes through [_handleSharedFiles]. The app still launches
  /// normally when there is no share (empty list -> no-op).
  void _initShareIntake() {
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handleSharedFiles(files);
      // Consume the initial intent so a later rebuild doesn't replay it.
      ReceiveSharingIntent.instance.reset();
      // Swallow plugin-unavailable errors (e.g. in tests / unsupported hosts)
      // so the browser still launches normally without a share.
    }).catchError((_) {});
    _shareSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedFiles, onError: (_) {});
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _shareSub?.cancel();
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
  /// relative to the source root; [SearchScreen] resolves them to absolute paths.
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
      switch (res.activation) {
        case ResourceActivation.openFolder: // a file's listing is never a dir
        case ResourceActivation.openExternally:
          _showActions(res);
        case ResourceActivation.viewImage:
          _openImage(res, [res]);
        case ResourceActivation.playVideo:
          _openVideo(res);
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

  void _openShares() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SharesScreen(client: _client),
    ));
  }

  /// Creates a public share link for [item] (single file or folder), surfacing
  /// the resulting URL in a copyable / shareable dialog. Errors are copyable.
  Future<void> _shareLink(FbResource item) async {
    await showCreateShareDialog(context, client: _client, item: item);
  }

  // --- item activation -------------------------------------------------------
  // Single tap/long-press funnels (the selection seam): when selection mode
  // lands, intercept here to toggle selection instead of activating the item.

  void _handleTap(FbResource item, List<FbResource> all) {
    // While selecting, a tap toggles membership — even for folders (navigation
    // is suspended) — so the user can build a set without leaving the grid.
    if (_selection.active) {
      _selection.toggle(item.path);
      return;
    }
    // Folders navigate; media opens the in-app viewer. Every other file (pdf,
    // text, audio, unknown types — [ResourceActivation.openExternally]) routes
    // to the action sheet, whose primary action is "Open with…" (hand-off to a
    // native app). The sheet is kept as the tap target for these files because,
    // unlike media (which host rename/delete/details inside their viewer), a
    // non-media file has no in-app viewer — so the sheet is the only place those
    // per-file actions (and Details) remain reachable.
    switch (item.activation) {
      case ResourceActivation.openFolder:
        _open(item.path);
      case ResourceActivation.viewImage:
        _openImage(item, all);
      case ResourceActivation.playVideo:
        _openVideo(item);
      case ResourceActivation.openExternally:
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
            if (!item.isDir)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open with…'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _openWith(item);
                },
              ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(item.isDir ? 'Download as zip' : 'Download'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _download(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Share link'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _shareLink(item);
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
    final choice = await _chooseSaveLocation();
    if (choice == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final token = await _freshToken();
    if (token == null) {
      showErrorSnackBar(messenger, 'Cannot download: session expired. Sign in again.');
      return;
    }
    final url = _client.rawDownloadUri(item.path, algo: item.isDir ? 'zip' : null);
    await _transfers.download(
      downloadUrl: url,
      token: token,
      filename: item.isDir ? '${item.name}.zip' : item.name,
      directory: choice.directory,
    );
    messenger.showSnackBar(SnackBar(content: Text('Downloading ${item.name}…')));
  }

  /// Downloads [item] to the app cache and hands it to a native Android app via
  /// open-with (product item 12). A no-app-available result — or any other
  /// failure — is surfaced as a copyable snackbar.
  Future<void> _openWith(FbResource item) async {
    final messenger = ScaffoldMessenger.of(context);
    final token = await _freshToken();
    if (token == null) {
      showErrorSnackBar(messenger, 'Cannot open: session expired. Sign in again.');
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('Opening ${item.name}…')));
    try {
      final path = await _transfers.downloadToCache(
        downloadUrl: _client.rawDownloadUri(item.path),
        token: token,
        filename: item.name,
      );
      final result = await OpenFilex.open(path);
      if (result.type == ResultType.done || !mounted) return;
      showErrorSnackBar(
        messenger,
        result.type == ResultType.noAppToOpen
            ? 'No app installed can open ${item.name}.'
            : 'Could not open ${item.name}: ${result.message}',
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(messenger, 'Could not open ${item.name}: $e');
    }
  }

  /// Asks where to save a download (product item 13). Shows the remembered
  /// folder — or "App storage" when none is set — and a "Change folder…" button
  /// that opens the SAF directory picker. A newly picked folder is held in local
  /// dialog state only and persisted as the new default when the user confirms
  /// with Download — tapping Cancel leaves the saved default untouched. Returns
  /// the chosen absolute directory (a null `directory` means the app's private
  /// storage), or null overall when the user cancels.
  Future<({String? directory})?> _chooseSaveLocation() async {
    final prefs = _prefs;
    var dir = prefs.downloadDir;
    return showDialog<({String? directory})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Save download to'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dir ?? 'App storage (default)',
                  style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Change folder…'),
                  onPressed: () async {
                    final chosen = await FilePicker.getDirectoryPath();
                    if (chosen == null) return;
                    setLocal(() => dir = chosen);
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () async {
                  // Persist the (possibly changed) folder only on confirm.
                  if (dir != prefs.downloadDir) await prefs.setDownloadDir(dir);
                  if (ctx.mounted) Navigator.pop(ctx, (directory: dir));
                },
                child: const Text('Download')),
          ],
        ),
      ),
    );
  }

  /// Lets the user pick/change the default download save-location from the
  /// overflow menu, persisting it in [PreferencesStore.downloadDir].
  Future<void> _setDownloadFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    final prefs = _prefs;
    final chosen = await FilePicker.getDirectoryPath();
    if (chosen == null) return;
    await prefs.setDownloadDir(chosen);
    messenger.showSnackBar(
        SnackBar(content: Text('Downloads will save to $chosen')));
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
    final choice = await _chooseSaveLocation();
    if (choice == null || !mounted) return;
    final token = await _freshToken();
    if (token == null) {
      showErrorSnackBar(messenger, 'Cannot download: session expired. Sign in again.');
      return;
    }
    final url = _client.rawBundleDownloadUri(_path, names, algo: 'zip');
    final base = _path == '/' ? 'files' : p.posix.basename(_path);
    _selection.exit();
    await _transfers.download(
      downloadUrl: url,
      token: token,
      filename: '$base.zip',
      directory: choice.directory,
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
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null || !mounted) return;
    final pending = [
      for (final f in result.files)
        if (f.path != null) (localPath: f.path!, name: f.name),
    ];
    await _uploadFilesToDir(pending, _path);
  }

  /// Recursively uploads a picked folder, recreating its subtree under the
  /// current directory. The server auto-creates parent dirs on upload, so we
  /// just send each file to its full relative path. The whole folder is one
  /// conflict unit: if a folder of the same name already exists the user is
  /// prompted once (overwrite / skip / keep-both renames the top folder).
  ///
  /// NOTE: on Android 13+ scoped storage, reading a SAF-picked directory via
  /// dart:io may require all-files-access (MANAGE_EXTERNAL_STORAGE). If listing
  /// fails with a permission error on a real device, we'll need permission_handler
  /// or a SAF/content-URI directory walk. Verified path works for app-readable dirs.
  Future<void> _uploadFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null || !mounted) return;
    final folderName = p.basename(dirPath);

    // Resolve a clash on the destination folder name before walking it.
    final existing = _visibleItems.map((e) => e.name).toSet();
    var effectiveFolder = folderName;
    var override = false;
    if (existing.contains(folderName)) {
      final decision = await _promptUploadConflict(folderName);
      if (decision == null || !mounted) return;
      switch (decision.choice) {
        case ConflictChoice.skip:
          return;
        case ConflictChoice.overwrite:
          override = true;
        case ConflictChoice.keepBoth:
          effectiveFolder = dedupedUploadName(existing, folderName);
      }
    }

    final token = await _freshToken();
    if (token == null) {
      showErrorSnackBar(messenger, 'Cannot upload: session expired. Sign in again.');
      return;
    }
    var count = 0;
    try {
      await for (final entity
          in Directory(dirPath).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: dirPath);
        final remote = p.posix.join(
            _path == '/' ? '' : _path, effectiveFolder, p.split(rel).join('/'));
        final target = remote.startsWith('/') ? remote : '/$remote';
        await _transfers.upload(
          uploadUrl: _client.uploadUri(target, override: override),
          token: token,
          localFilePath: entity.path,
        );
        count++;
      }
    } catch (e) {
      showErrorSnackBar(messenger, 'Folder upload failed: $e');
      return;
    }
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(count == 0
          ? 'No files found in "$folderName"'
          : 'Uploading $count file(s) from "$effectiveFolder"…'),
    ));
  }

  /// Refreshes the session ([AuthController.ensureFreshSession]) so a long
  /// transfer carries a current token, then returns it (or null if the session
  /// is gone). Call immediately before enqueuing.
  Future<String?> _freshToken() async {
    await context.read<AuthController>().ensureFreshSession();
    return _client.token;
  }

  /// Enqueues [files] into [destDir], resolving per-file name clashes against
  /// the destination's existing entries. On the first conflict the user picks
  /// overwrite / skip / keep-both (with an "apply to all" toggle for the rest of
  /// the batch); the concrete action + final name come from the pure
  /// [resolveUploadConflict]. Keep-both names also dedupe against each other
  /// within the same batch (the reserved-name [taken] set). Uploads pass
  /// `override=true` only for an explicit overwrite.
  Future<void> _uploadFilesToDir(
      List<({String localPath, String name})> files, String destDir) async {
    if (files.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);

    // Snapshot the destination's current names so conflicts can be detected and
    // keep-both variants generated purely. A listing failure degrades to "no
    // known names" — uploads then go out with override=false, so the server
    // (which 409s on an un-overridden clash) still protects existing files.
    final taken = <String>{};
    try {
      final listing = await _client.listDirectory(destDir);
      taken.addAll(listing.items.map((e) => e.name));
    } catch (_) {/* best-effort */}
    if (!mounted) return;

    final token = await _freshToken();
    if (token == null) {
      showErrorSnackBar(messenger, 'Cannot upload: session expired. Sign in again.');
      return;
    }

    ConflictChoice? bulk;
    var uploaded = 0, skipped = 0;
    for (final f in files) {
      // Determine the policy for this file: no clash needs none; otherwise reuse
      // the bulk choice or prompt for one.
      var policy = ConflictChoice.overwrite; // unused when there's no clash
      if (taken.contains(f.name)) {
        if (bulk != null) {
          policy = bulk;
        } else {
          final decision = await _promptUploadConflict(f.name);
          if (decision == null) break; // user cancelled — stop the remainder
          policy = decision.choice;
          if (decision.applyAll) bulk = policy;
        }
      }
      final plan = resolveUploadConflict(
          existingNames: taken, desiredName: f.name, policy: policy);
      if (plan.action == UploadAction.skip) {
        skipped++;
        continue;
      }
      // Reserve the chosen name so a later same-named file in this batch clashes
      // (and dedupes) against it too.
      taken.add(plan.name);
      final target = _childPath(destDir, plan.name);
      await _transfers.upload(
        uploadUrl: _client.uploadUri(target,
            override: plan.action == UploadAction.overwrite),
        token: token,
        localFilePath: f.localPath,
      );
      uploaded++;
    }
    if (!mounted) return;
    final parts = [
      if (uploaded > 0) 'Uploading $uploaded file(s)…',
      if (skipped > 0) 'skipped $skipped',
    ];
    messenger.showSnackBar(SnackBar(
        content: Text(parts.isEmpty ? 'Nothing to upload' : parts.join(', '))));
  }

  /// Joins a child [name] onto a `/`-rooted [dir], yielding an absolute target.
  String _childPath(String dir, String name) {
    final joined = p.posix.join(dir == '/' ? '' : dir, name);
    return joined.startsWith('/') ? joined : '/$joined';
  }

  /// Prompts for an upload naming clash on [name]: overwrite / skip / keep-both,
  /// plus an "apply to all remaining" toggle. Returns null if the user cancels
  /// (which aborts the rest of the batch). Mirrors the move/copy
  /// [_resolveConflict] dialog.
  Future<({ConflictChoice choice, bool applyAll})?> _promptUploadConflict(
      String name) async {
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
              Text('"$name" already exists in the destination.'),
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
    if (choice == null) return null;
    return (choice: choice, applyAll: applyAll);
  }

  /// Handles files shared into the app from another app (SEND / SEND_MULTIPLE).
  /// Brings up the destination picker, then uploads the file-backed shares
  /// (images/videos/files; text/url shares are ignored) through the same
  /// conflict-aware path as a manual upload. Re-entrant guard prevents two
  /// share events from racing.
  Future<void> _handleSharedFiles(List<SharedMediaFile> shared) async {
    final pending = [
      for (final s in shared)
        if (s.type != SharedMediaType.text && s.type != SharedMediaType.url)
          (localPath: s.path, name: p.basename(s.path)),
    ];
    if (_handlingShare || !mounted) return;
    if (pending.isEmpty) {
      // An empty list is the normal no-share launch; a non-empty share with no
      // file-backed items (a stray text/link share) gets explicit feedback
      // rather than the app silently coming forward and doing nothing.
      if (shared.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Only files can be uploaded')));
      }
      return;
    }
    _handlingShare = true;
    try {
      final dest = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => DestinationPicker(
            client: _client,
            title: 'Upload ${pending.length} file(s) to',
            confirmLabel: 'Upload here',
            initialPath: _path,
            canCreate: context.read<AuthController>().user?.canCreate ?? false,
          ),
        ),
      );
      if (dest == null || !mounted) return;
      await _uploadFilesToDir(pending, dest);
      // Refresh if the share landed in the directory currently on screen.
      if (mounted && dest == _path) _open(_path);
    } finally {
      _handlingShare = false;
    }
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
        _transfersAction(context),
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
            if (v == 'shares') _openShares();
            if (v == 'dlfolder') _setDownloadFolder();
            if (v == 'lock') context.read<AuthController>().signOut();
            if (v == 'forget') context.read<AuthController>().signOut(forget: true);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'status', child: Text('Status')),
            const PopupMenuItem(value: 'shares', child: Text('Shared links')),
            const PopupMenuItem(
                value: 'dlfolder', child: Text('Download folder')),
            PopupMenuItem(value: 'lock', child: Text('Lock (${user?.username ?? ''})')),
            const PopupMenuItem(value: 'forget', child: Text('Sign out & forget')),
          ],
        ),
      ],
    );
  }

  /// Transfers app-bar action: an icon that opens [TransfersScreen], badged with
  /// the live count of in-flight transfers (hidden when zero). The count folds
  /// the service's broadcast record stream via [activeTransferCount].
  Widget _transfersAction(BuildContext context) {
    return StreamBuilder<List<TransferRecord>>(
      stream: _transfers.records,
      initialData: _transfers.current,
      builder: (context, snap) {
        final count = activeTransferCount(snap.data ?? const []);
        final button = IconButton(
          icon: const Icon(Icons.swap_vert),
          tooltip: 'Transfers',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TransfersScreen()),
          ),
        );
        if (count == 0) return button;
        return Badge(label: Text('$count'), child: button);
      },
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
          _barAction(Icons.link, 'Share', single ? _shareSelected : null),
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

  /// Shares the lone selected item, then leaves selection mode. Reuses the
  /// per-item [_shareLink] flow so folders/media remain shareable from the bar.
  Future<void> _shareSelected() async {
    final items = _selectedResources();
    if (items.length != 1) return;
    final item = items.single;
    _selection.exit();
    await _shareLink(item);
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
/// Extracted from [BrowserScreen] so it can be extended cleanly: multiselect
/// adds a `selectedPaths` set + selection chrome here, and transfers can surface
/// per-tile progress — all without touching the screen's navigation/sort/error
/// wiring. Tap and long-press are reported per
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

