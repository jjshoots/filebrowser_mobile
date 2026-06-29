import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/transfers/transfer_record.dart';

DownloadTask _dl({bool allowPause = true}) => DownloadTask(
    taskId: 'dl1',
    url: 'https://x/api/resources/download/a.bin',
    filename: 'a.bin',
    allowPause: allowPause);

UploadTask _ul() => UploadTask(
    taskId: 'ul1',
    url: 'https://x/api/resources/a.bin',
    filename: 'a.bin',
    httpRequestMethod: 'POST',
    post: 'binary');

void main() {
  group('applyTaskUpdate', () {
    test('first status update seeds a record at 0 progress', () {
      final r = applyTaskUpdate(
          null, TaskStatusUpdate(_dl(), TaskStatus.enqueued));
      expect(r.status, TaskStatus.enqueued);
      expect(r.progress, 0);
      expect(r.isActive, isTrue);
    });

    test('progress update merges over the prior status', () {
      var r = applyTaskUpdate(null, TaskStatusUpdate(_dl(), TaskStatus.running));
      r = applyTaskUpdate(r, TaskProgressUpdate(_dl(), 0.42, 1000));
      expect(r.status, TaskStatus.running); // preserved
      expect(r.progress, closeTo(0.42, 1e-9));
      expect(r.expectedFileSize, 1000);
    });

    test('status update preserves the last real progress', () {
      var r = applyTaskUpdate(null, TaskProgressUpdate(_dl(), 0.7, 2000));
      r = applyTaskUpdate(r, TaskStatusUpdate(_dl(), TaskStatus.paused));
      expect(r.status, TaskStatus.paused);
      expect(r.progress, closeTo(0.7, 1e-9));
      expect(r.expectedFileSize, 2000);
    });

    test('completion pins progress to 1.0', () {
      var r = applyTaskUpdate(null, TaskProgressUpdate(_dl(), 0.9, 2000));
      r = applyTaskUpdate(r, TaskStatusUpdate(_dl(), TaskStatus.complete));
      expect(r.progress, 1.0);
      expect(r.isComplete, isTrue);
      expect(r.isActive, isFalse);
    });

    test('negative progress sentinels keep the last good fraction', () {
      var r = applyTaskUpdate(null, TaskProgressUpdate(_dl(), 0.55, 2000));
      // -1.0 is the "failed" sentinel emitted on the progress stream.
      r = applyTaskUpdate(r, TaskProgressUpdate(_dl(), -1.0));
      expect(r.progress, closeTo(0.55, 1e-9));
    });
  });

  group('action flags', () {
    test('a running, pausable download can pause/cancel but not resume/retry',
        () {
      final r = applyTaskUpdate(
          null, TaskStatusUpdate(_dl(), TaskStatus.running));
      expect(r.canPause, isTrue);
      expect(r.canCancel, isTrue);
      expect(r.canResume, isFalse);
      expect(r.canRetry, isFalse);
    });

    test('a running upload cannot pause (POST is not pausable)', () {
      final r =
          applyTaskUpdate(null, TaskStatusUpdate(_ul(), TaskStatus.running));
      expect(r.isUpload, isTrue);
      expect(r.canPause, isFalse);
      expect(r.canCancel, isTrue);
    });

    test('a paused download can resume', () {
      final r = applyTaskUpdate(
          null, TaskStatusUpdate(_dl(), TaskStatus.paused));
      expect(r.canResume, isTrue);
      expect(r.canPause, isFalse);
    });

    test('a failed/canceled transfer can retry, not pause/resume', () {
      final failed =
          applyTaskUpdate(null, TaskStatusUpdate(_ul(), TaskStatus.failed));
      expect(failed.isFailed, isTrue);
      expect(failed.canRetry, isTrue);
      expect(failed.isActive, isFalse);

      final canceled = applyTaskUpdate(
          null, TaskStatusUpdate(_dl(), TaskStatus.canceled));
      expect(canceled.canRetry, isTrue);
    });
  });

  group('activeTransferCount (badge)', () {
    TransferRecord rec(TaskStatus s, {bool upload = false}) =>
        applyTaskUpdate(null, TaskStatusUpdate(upload ? _ul() : _dl(), s));

    test('counts only non-final states', () {
      final records = [
        rec(TaskStatus.running),
        rec(TaskStatus.enqueued),
        rec(TaskStatus.paused),
        rec(TaskStatus.waitingToRetry),
        rec(TaskStatus.complete),
        rec(TaskStatus.failed),
        rec(TaskStatus.canceled),
      ];
      expect(activeTransferCount(records), 4);
    });

    test('empty -> zero', () {
      expect(activeTransferCount(const []), 0);
    });
  });
}
