import 'package:background_downloader/background_downloader.dart';

/// An in-memory snapshot of one tracked transfer, folded from the stream of
/// [TaskUpdate]s `background_downloader` emits (status changes *and* progress
/// arrive as separate events, so the record merges the latest of each).
///
/// Kept free of widgets so the [TaskUpdate] -> record mapping and the derived
/// action flags (pause/resume/cancel/retry, active) are unit-testable; the
/// transfers screen renders straight from these.
class TransferRecord {
  const TransferRecord({
    required this.task,
    required this.status,
    required this.progress,
    this.expectedFileSize = -1,
  });

  /// The task as enqueued (retained so retry can re-enqueue it with a fresh
  /// token, and so pause/resume can pass the concrete [DownloadTask]).
  final Task task;
  final TaskStatus status;

  /// Last known fraction in `0.0..1.0`. The native sentinels (-1 failed, -2
  /// canceled, …) are never stored here — [_foldProgress] keeps the last real
  /// fraction so a failed transfer still shows how far it got.
  final double progress;

  /// Total size in bytes once known mid-flight (`-1` until then).
  final int expectedFileSize;

  String get id => task.taskId;
  String get filename => task.filename;
  bool get isUpload => task is UploadTask;

  /// True while the transfer may still change state (enqueued / running /
  /// waiting-to-retry / paused) — i.e. it counts toward the app-bar badge.
  bool get isActive => status.isNotFinalState;

  bool get isComplete => status == TaskStatus.complete;
  bool get isFailed =>
      status == TaskStatus.failed || status == TaskStatus.notFound;

  /// Pause is a download-only, opt-in capability in `background_downloader`
  /// (POST uploads can't pause — see [TransferService]); only offer it while
  /// the download is actively running.
  bool get canPause =>
      status == TaskStatus.running && task is DownloadTask && task.allowPause;
  bool get canResume => status == TaskStatus.paused;
  bool get canCancel => isActive;
  bool get canRetry => isFailed || status == TaskStatus.canceled;

  TransferRecord copyWith({
    TaskStatus? status,
    double? progress,
    int? expectedFileSize,
  }) =>
      TransferRecord(
        task: task,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        expectedFileSize: expectedFileSize ?? this.expectedFileSize,
      );
}

/// Folds a single [update] into the running [prev] record (or creates the first
/// one). PURE: status and progress updates arrive separately, so a status event
/// preserves the last progress and a progress event preserves the last status.
/// This is the seam the transfers UI and the active-count badge are built on.
TransferRecord applyTaskUpdate(TransferRecord? prev, TaskUpdate update) {
  final task = update.task;
  switch (update) {
    case TaskStatusUpdate(:final status):
      return TransferRecord(
        task: task,
        status: status,
        progress: _foldProgress(status, prev?.progress ?? 0),
        expectedFileSize: prev?.expectedFileSize ?? -1,
      );
    case TaskProgressUpdate(:final progress, :final expectedFileSize):
      return TransferRecord(
        task: task,
        status: prev?.status ?? TaskStatus.running,
        // Negative values are state sentinels (failed/canceled/…), not real
        // fractions — keep the last good one for display.
        progress: progress >= 0 ? progress : (prev?.progress ?? 0),
        expectedFileSize:
            expectedFileSize >= 0 ? expectedFileSize : (prev?.expectedFileSize ?? -1),
      );
  }
}

/// A completed transfer is pinned to 1.0; otherwise the last real fraction is
/// preserved across a status change.
double _foldProgress(TaskStatus status, double previous) =>
    status == TaskStatus.complete ? 1.0 : previous;

/// Number of [records] still in flight — drives the app-bar badge. PURE.
int activeTransferCount(Iterable<TransferRecord> records) =>
    records.where((r) => r.isActive).length;
