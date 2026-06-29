import 'package:path/path.dart' as p;

import '../api/filebrowser_client.dart';
import '../api/models.dart';

/// Which PATCH action a batch performs (`action=rename` vs `action=copy`).
enum TransferOp { move, copy }

/// The user's decision when a destination path already exists.
enum ConflictChoice {
  /// Replace the existing item (`override=true`).
  overwrite,

  /// Leave the existing item; don't transfer this one.
  skip,

  /// Transfer under a non-colliding `name(n).ext` variant.
  keepBoth,
}

String _stripTrailingSlash(String s) =>
    s.length > 1 && s.endsWith('/') ? s.substring(0, s.length - 1) : s;

/// Computes the destination path for moving/copying [itemPath] into the
/// directory [destDir]. Both are `/`-rooted POSIX server paths; the result is
/// `<destDir>/<name>` with the item's basename preserved verbatim (unicode and
/// spaces included).
///
/// ```
/// destinationPath('/a/b/x.jpg', '/c') == '/c/x.jpg'
/// destinationPath('/x.jpg', '/')      == '/x.jpg'
/// ```
String destinationPath(String itemPath, String destDir) {
  final name = p.posix.basename(_stripTrailingSlash(itemPath));
  final base = destDir == '/' ? '' : _stripTrailingSlash(destDir);
  return '$base/$name';
}

/// Whether moving/copying the folder [srcPath] into [destDir] would place it
/// inside itself or one of its own descendants — an illegal, data-eating
/// operation. Guards both the destination picker and the per-item batch loop.
///
/// ```
/// isMoveIntoSelfOrDescendant('/a',   '/a')     == true   // into itself
/// isMoveIntoSelfOrDescendant('/a',   '/a/b')   == true   // into a descendant
/// isMoveIntoSelfOrDescendant('/a',   '/ab')    == false  // sibling-ish prefix
/// isMoveIntoSelfOrDescendant('/a',   '/c')     == false
/// ```
bool isMoveIntoSelfOrDescendant(String srcPath, String destDir) {
  final src = _stripTrailingSlash(srcPath);
  final dest = _stripTrailingSlash(destDir);
  if (src == '/') return false;
  return dest == src || dest.startsWith('$src/');
}

/// Per-item outcome of a batch transfer.
class BatchItemResult {
  BatchItemResult(this.item, {this.skipped = false, this.error});

  final FbResource item;
  final bool skipped;

  /// Non-null when the item failed (network error, illegal move, …).
  final Object? error;

  bool get ok => !skipped && error == null;
}

/// Aggregate result of a batch transfer.
class BatchResult {
  BatchResult(this.results, {this.aborted = false});

  final List<BatchItemResult> results;

  /// True when the user cancelled out of a conflict prompt mid-batch.
  final bool aborted;

  int get succeeded => results.where((r) => r.ok).length;
  int get skipped => results.where((r) => r.skipped).length;
  List<BatchItemResult> get failures =>
      results.where((r) => r.error != null).toList(growable: false);
}

/// Resolves a single naming conflict; returns the user's [ConflictChoice], or
/// `null` to abort the rest of the batch.
typedef ConflictResolver = Future<ConflictChoice?> Function(
    FbResource item, String targetPath);

/// Moves or copies [items] into [destDir], one server PATCH per item.
///
/// For each item the target is [destinationPath]; if it already exists
/// ([FileBrowserClient.resourceExists]) the caller's [onConflict] decides
/// overwrite / skip / keep-both. Overwrite just sends (quantum always
/// overwrites); keep-both passes `keepBoth:true` so the server auto-versions the
/// destination; skip omits the item. Folder *moves* into self/descendant are
/// recorded as failures and never sent. Per-item errors are captured (not
/// thrown) so one bad item doesn't abort the others; returning `null` from
/// [onConflict] aborts the remainder. The orchestration is kept here, free of
/// widgets, so it is unit-testable against a mock-adapter client.
Future<BatchResult> runTransferBatch({
  required FileBrowserClient client,
  required TransferOp op,
  required List<FbResource> items,
  required String destDir,
  required ConflictResolver onConflict,
}) async {
  final results = <BatchItemResult>[];
  for (final item in items) {
    if (op == TransferOp.move &&
        item.isDir &&
        isMoveIntoSelfOrDescendant(item.path, destDir)) {
      results.add(BatchItemResult(item,
          error: "Can't move a folder into itself or a subfolder"));
      continue;
    }

    final target = destinationPath(item.path, destDir);
    var overwrite = false;
    var keepBoth = false;
    try {
      if (await client.resourceExists(target)) {
        final choice = await onConflict(item, target);
        if (choice == null) return BatchResult(results, aborted: true);
        switch (choice) {
          case ConflictChoice.skip:
            results.add(BatchItemResult(item, skipped: true));
            continue;
          case ConflictChoice.overwrite:
            // Overwriting a file with itself (copying/moving an item into the
            // folder it already lives in) is a no-op the server rejects with
            // "cannot copy a file to itself"; treat it as a skip instead.
            if (_stripTrailingSlash(item.path) == _stripTrailingSlash(target)) {
              results.add(BatchItemResult(item, skipped: true));
              continue;
            }
            overwrite = true;
          case ConflictChoice.keepBoth:
            keepBoth = true;
        }
      }

      if (op == TransferOp.move) {
        await client.move(item.path, target,
            overwrite: overwrite, keepBoth: keepBoth);
      } else {
        await client.copy(item.path, target,
            overwrite: overwrite, keepBoth: keepBoth);
      }
      results.add(BatchItemResult(item));
    } catch (e) {
      results.add(BatchItemResult(item, error: e));
    }
  }
  return BatchResult(results);
}
