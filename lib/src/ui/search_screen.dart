import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import 'error_display.dart';

/// What a tapped search hit resolves to. Drives the browser's dispatch
/// (navigate / open viewer / show actions) without the search screen needing to
/// know about any of those flows.
enum SearchTargetKind { directory, image, video, other }

/// Classifies a raw search hit by reusing [FbResource]'s extension heuristics
/// (folders win first). PURE — unit-tested in `search_screen_test.dart`.
SearchTargetKind classifySearchResult(FbSearchResult r) {
  if (r.isDir) return SearchTargetKind.directory;
  final probe = FbResource(path: r.path, name: r.name, size: 0, isDir: false);
  if (probe.isImage) return SearchTargetKind.image;
  if (probe.isVideo) return SearchTargetKind.video;
  return SearchTargetKind.other;
}

/// Resolves a server search hit (whose [relative] path is relative to the
/// source root, with no leading slash, e.g. `Documents/beta.md`, or `dir/` for
/// folders) into an absolute server path under [root].
///
/// Callers resolve against the source root (`/`), since quantum returns hit
/// paths from the source root regardless of the searched scope. We strip any
/// stray leading slash and the trailing slash folders carry, then posix-join
/// onto [root]. PURE — see `search_screen_test.dart` (root/nested/unicode cases).
String resolveSearchPath(String root, String relative) {
  var rel = relative.trim();
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  while (rel.length > 1 && rel.endsWith('/')) {
    rel = rel.substring(0, rel.length - 1);
  }
  final base = root.isEmpty ? '/' : root;
  if (rel.isEmpty) return base;
  return p.posix.join(base, rel);
}

/// The browser's hand-off when the user picks a search hit: the absolute server
/// [path] and whether it is a directory. The browser dispatches (navigate vs.
/// fetch+activate) — keeping all viewer/action wiring in one place.
typedef SearchPick = ({String path, bool isDir});

/// Full-screen search scoped to [root] (the directory the browser was showing).
///
/// Debounces input, calls `client.search(root, query)`, and renders hits with a
/// type icon / media thumbnail, the file name, and its parent directory. Tapping
/// a hit pops the screen returning a [SearchPick] so the browser can navigate
/// into folders or open files via its existing flows. Empty-query / no-results /
/// error (copyable) states are all handled.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.client, required this.root});

  final FileBrowserClient client;

  /// Absolute server path of the directory the search is scoped to.
  final String root;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// Monotonic id so a slow earlier search can't overwrite a newer result set.
  int _requestId = 0;

  /// Live text in the field, updated synchronously on every keystroke — drives
  /// the clear (X) affordance so it tracks the input without the debounce lag.
  String _liveText = '';

  /// The query the currently-shown results/empty-state reflect (set in [_run],
  /// i.e. after the debounce). Distinct from [_liveText] on purpose.
  String _query = '';
  bool _loading = false;
  String? _error;
  List<FbSearchResult> _results = const [];

  static const _debounceDelay = Duration(milliseconds: 350);

  /// Quantum's search rejects queries shorter than this (HTTP 400, "query is
  /// too short"), so we hold off firing one and keep prompting the user instead.
  static const _minQueryLen = 3;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _liveText = value);
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _run(value));
  }

  /// Manual submit / clear: skip the debounce and run immediately, cancelling
  /// any pending timer so a stale duplicate request can't fire afterwards.
  void _runNow(String value) {
    _debounce?.cancel();
    setState(() => _liveText = value);
    _run(value);
  }

  Future<void> _run(String raw) async {
    final query = raw.trim();
    setState(() {
      _query = query;
      _error = null;
    });
    if (query.length < _minQueryLen) {
      // Too short for the server to accept: clear results and let the body show
      // the "keep typing" hint rather than firing a doomed 400 request.
      setState(() {
        _loading = false;
        _results = const [];
      });
      return;
    }
    final id = ++_requestId;
    setState(() => _loading = true);
    try {
      final hits = await widget.client.search(widget.root, query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _results = hits;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _pick(FbSearchResult hit) {
    // Quantum returns hit paths relative to the source root, so resolve from `/`
    // rather than the searched directory.
    final abs = resolveSearchPath('/', hit.path);
    Navigator.of(context).pop<SearchPick>((path: abs, isDir: hit.isDir));
  }

  @override
  Widget build(BuildContext context) {
    final rootLabel = widget.root == '/' ? 'Files' : p.posix.basename(widget.root);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: 'Search in $rootLabel…',
            suffixIcon: _liveText.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      _runNow('');
                    },
                  ),
          ),
          onChanged: _onChanged,
          onSubmitted: _runNow,
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return CopyableErrorView(
        message: _error!,
        onRetry: () => _run(_query),
      );
    }
    if (_query.length < _minQueryLen) {
      return _Hint(
          icon: Icons.search,
          text: _query.isEmpty
              ? 'Type to search this folder'
              : 'Keep typing (at least $_minQueryLen characters)');
    }
    if (_results.isEmpty) {
      return _Hint(icon: Icons.search_off, text: 'No results for "$_query"');
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _ResultTile(
        result: _results[i],
        absolutePath: resolveSearchPath('/', _results[i].path),
        client: widget.client,
        onTap: () => _pick(_results[i]),
      ),
    );
  }
}

/// One search hit: type icon (or media thumbnail), name, and parent directory.
class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.absolutePath,
    required this.client,
    required this.onTap,
  });

  final FbSearchResult result;
  final String absolutePath;
  final FileBrowserClient client;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final parent = p.posix.dirname(absolutePath);
    final kind = classifySearchResult(result);
    return ListTile(
      leading: _leading(context, kind),
      title: Text(result.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(parent, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }

  Widget _leading(BuildContext context, SearchTargetKind kind) {
    if (kind == SearchTargetKind.image || kind == SearchTargetKind.video) {
      final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
      return SizedBox(
        width: 44,
        height: 44,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: client.previewUri(absolutePath).toString(),
                httpHeaders: client.authHeaders,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: surface),
                errorWidget: (_, __, ___) => Container(
                  color: surface,
                  child: Icon(
                      kind == SearchTargetKind.video
                          ? Icons.movie
                          : Icons.broken_image,
                      size: 20,
                      color: Colors.grey),
                ),
              ),
              if (kind == SearchTargetKind.video)
                const Center(
                  child: Icon(Icons.play_circle_fill,
                      color: Colors.white70, size: 20),
                ),
            ],
          ),
        ),
      );
    }
    return Icon(switch (kind) {
      SearchTargetKind.directory => Icons.folder,
      _ => Icons.insert_drive_file,
    });
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: muted),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: muted)),
        ],
      ),
    );
  }
}
