import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import 'transfer_record.dart';

/// Maps a user-chosen public directory path (from the SAF directory picker) to
/// a sub-directory *within* the platform's shared "Downloads" collection, so a
/// chosen-folder download can be relocated there via MediaStore instead of
/// writing to an arbitrary absolute path (which scoped storage denies on
/// Android 11+ without `MANAGE_EXTERNAL_STORAGE`).
///
/// A path already under a `Download`/`Downloads` root yields the portion after
/// that segment (e.g. `…/Download/Trips/2024` -> `Trips/2024`, `…/Download` ->
/// `''`). Any other location nests under the chosen folder's own name so files
/// still land grouped, rather than spilling into the Downloads root.
String sharedDownloadsSubdir(String absoluteDir) {
  final segs = p.split(absoluteDir).where((s) => s.isNotEmpty && s != '/').toList();
  final idx = segs.lastIndexWhere(
      (s) => s.toLowerCase() == 'download' || s.toLowerCase() == 'downloads');
  if (idx >= 0) return segs.sublist(idx + 1).join('/');
  return segs.isNotEmpty ? segs.last : '';
}

/// Wraps `background_downloader` so uploads/downloads run in a native
/// foreground service and continue when the app is backgrounded or closed.
///
/// File Browser specifics:
///  - Download: GET `/api/raw/<path>` with `X-Auth` header.
///  - Upload:   POST `/api/resources/<path>?override=…` with the raw file
///              bytes as the body — i.e. a *binary* upload (not multipart).
///
/// Beyond enqueueing, the service folds the package's [TaskUpdate] stream into a
/// small in-memory map of [TransferRecord]s (keyed by taskId) and re-broadcasts
/// it via [records], so the transfers screen and the app-bar badge can render
/// live state without each re-subscribing to the raw update stream. The
/// enqueue API ([download]/[upload]) is unchanged.
class TransferService {
  static const _group = 'filebrowser';
  // A separate, untracked group for the short-lived open-with cache fetch, so
  // it neither shows up in the transfers list nor is persisted by trackTasks.
  static const _openGroup = 'filebrowser_open';

  final Map<String, TransferRecord> _records = {};
  final StreamController<List<TransferRecord>> _recordsController =
      StreamController<List<TransferRecord>>.broadcast();
  StreamSubscription<TaskUpdate>? _updatesSub;

  // taskId -> shared-Downloads sub-directory for downloads bound for a chosen
  // public folder. The file is fetched into app storage and relocated there on
  // completion (see [download] / [_ingest]).
  final Map<String, String> _sharedTargets = {};

  Future<void> init() async {
    // configureNotification is synchronous and fluent (returns FileDownloader).
    FileDownloader().configureNotification(
      running: const TaskNotification('Transferring', '{filename}'),
      complete: const TaskNotification('Done', '{filename}'),
      error: const TaskNotification('Failed', '{filename}'),
      progressBar: true,
    );
    // Fold every status/progress update into the in-memory record map so the
    // UI sees a single, merged view per task.
    _updatesSub = FileDownloader().updates.listen(_ingest);
    // Persist task records so progress/state survives process death.
    await FileDownloader().trackTasks();
  }

  void _ingest(TaskUpdate update) {
    final id = update.task.taskId;
    _records[id] = applyTaskUpdate(_records[id], update);
    _emit();
    // A chosen-folder download finished in app storage: relocate it into the
    // shared Downloads collection (MediaStore), which needs no storage
    // permission on modern Android.
    if (update is TaskStatusUpdate &&
        update.status == TaskStatus.complete &&
        _sharedTargets.containsKey(id)) {
      final subdir = _sharedTargets.remove(id)!;
      final task = update.task;
      if (task is DownloadTask) {
        unawaited(_relocateToDownloads(task, subdir));
      }
    }
  }

  Future<void> _relocateToDownloads(DownloadTask task, String subdir) async {
    try {
      await FileDownloader().moveToSharedStorage(
        task,
        SharedStorage.downloads,
        directory: subdir,
      );
    } catch (_) {
      // Best-effort: if the move fails the file simply remains in app storage.
    }
  }

  void _emit() {
    if (!_recordsController.isClosed) {
      _recordsController.add(current);
    }
  }

  /// Live, broadcast view of every tracked transfer (most-recently-updated
  /// first), re-emitted on each status/progress change.
  Stream<List<TransferRecord>> get records => _recordsController.stream;

  /// Current snapshot of tracked transfers, active ones first.
  List<TransferRecord> get current {
    final list = _records.values.toList();
    list.sort((a, b) {
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return 0;
    });
    return list;
  }

  /// Enqueue a background download of [downloadUrl].
  ///
  /// The file is always fetched into the app's own documents dir first. With no
  /// [directory] it stays there. When [directory] is the chosen public
  /// save-location (product item 13), the task is registered in [_sharedTargets]
  /// and, on completion, relocated into the platform's shared "Downloads"
  /// collection via [FileDownloader.moveToSharedStorage] (see [_ingest]).
  ///
  /// Relocating through MediaStore — rather than writing straight to the picked
  /// absolute path — is what makes this work on Android 11+ scoped storage,
  /// where direct writes outside the app sandbox are denied and the app holds no
  /// `WRITE_EXTERNAL_STORAGE`/`MANAGE_EXTERNAL_STORAGE`. The chosen path maps to
  /// a Downloads sub-directory via [sharedDownloadsSubdir]. (Device-only
  /// behaviour; not exercised by unit tests.)
  Future<String> download({
    required Uri downloadUrl,
    required String token,
    required String filename,
    String? directory,
  }) async {
    final task = DownloadTask(
      url: downloadUrl.toString(),
      filename: filename,
      baseDirectory: BaseDirectory.applicationDocuments,
      headers: {'X-Auth': token},
      group: _group,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 3,
    );
    if (directory != null && directory.isNotEmpty) {
      _sharedTargets[task.taskId] = sharedDownloadsSubdir(directory);
    }
    await FileDownloader().enqueue(task);
    return task.taskId;
  }

  /// Foreground-downloads [downloadUrl] into the app's temporary cache and
  /// returns the resulting absolute file path once complete, for handing to a
  /// native app via open-with (product item 12). Unlike [download] this awaits
  /// completion and stays out of the tracked transfers list (its own group, no
  /// progress folding). Throws if the download does not complete.
  Future<String> downloadToCache({
    required Uri downloadUrl,
    required String token,
    required String filename,
  }) async {
    final task = DownloadTask(
      url: downloadUrl.toString(),
      filename: filename,
      headers: {'X-Auth': token},
      baseDirectory: BaseDirectory.temporary,
      group: _openGroup,
      updates: Updates.status,
      retries: 1,
    );
    final result = await FileDownloader().download(task);
    if (result.status != TaskStatus.complete) {
      throw Exception('Download failed (${result.status.name})');
    }
    return task.filePath();
  }

  /// Enqueue a background binary upload of [localFilePath] to [uploadUrl].
  Future<String> upload({
    required Uri uploadUrl,
    required String token,
    required String localFilePath,
  }) async {
    // UploadTask locates the source file via baseDirectory + directory +
    // filename, so split the absolute path the file picker gave us.
    final (baseDirectory, directory, filename) =
        await Task.split(filePath: localFilePath);
    final task = UploadTask(
      url: uploadUrl.toString(),
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      httpRequestMethod: 'POST',
      post: 'binary', // raw bytes in the body, as File Browser expects
      headers: {'X-Auth': token},
      group: _group,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
    await FileDownloader().enqueue(task);
    return task.taskId;
  }

  /// Pause a running, pausable download. POST uploads cannot pause in
  /// `background_downloader` (it requires GET), so this is a no-op (returns
  /// false) for uploads — the UI hides the control via [TransferRecord.canPause].
  Future<bool> pause(TransferRecord record) async {
    final task = record.task;
    if (task is! DownloadTask) return false;
    return FileDownloader().pause(task);
  }

  /// Resume a paused download (see [pause]).
  Future<bool> resume(TransferRecord record) async {
    final task = record.task;
    if (task is! DownloadTask) return false;
    return FileDownloader().resume(task);
  }

  /// Cancel a transfer (any state); the record settles to `canceled`.
  Future<bool> cancel(TransferRecord record) =>
      FileDownloader().cancelTaskWithId(record.id);

  /// Re-enqueue a failed/canceled transfer, refreshing its `X-Auth` header with
  /// [token] so a long-idle task carries a current session. The original task
  /// object is reused (its header map is mutable), so its progress notification
  /// and identity are preserved.
  Future<String> retry(TransferRecord record, {required String token}) async {
    final task = record.task;
    task.headers['X-Auth'] = token;
    await FileDownloader().enqueue(task);
    return task.taskId;
  }

  /// Drop finished (complete/failed/canceled) records from the in-memory list,
  /// e.g. when the user clears the transfers screen. Active transfers are kept.
  void clearFinished() {
    _records.removeWhere((_, r) => !r.isActive);
    _emit();
  }

  /// Stream of raw progress/status updates (retained for back-compat).
  Stream<TaskUpdate> get updates => FileDownloader().updates;

  void dispose() {
    _updatesSub?.cancel();
    _recordsController.close();
  }
}
