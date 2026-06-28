import 'package:background_downloader/background_downloader.dart';

/// Wraps `background_downloader` so uploads/downloads run in a native
/// foreground service and continue when the app is backgrounded or closed.
///
/// File Browser specifics:
///  - Download: GET `/api/raw/<path>` with `X-Auth` header.
///  - Upload:   POST `/api/resources/<path>?override=true` with the raw file
///              bytes as the body — i.e. a *binary* upload (not multipart).
class TransferService {
  static const _group = 'filebrowser';

  Future<void> init() async {
    await FileDownloader().configureNotification(
      running: const TaskNotification('Transferring', '{filename}'),
      complete: const TaskNotification('Done', '{filename}'),
      error: const TaskNotification('Failed', '{filename}'),
      progressBar: true,
    );
    // Persist task records so progress/state survives process death.
    await FileDownloader().trackTasks();
  }

  /// Enqueue a background download of [downloadUrl] to the app's documents dir.
  Future<String> download({
    required Uri downloadUrl,
    required String token,
    required String filename,
  }) async {
    final task = DownloadTask(
      url: downloadUrl.toString(),
      filename: filename,
      headers: {'X-Auth': token},
      group: _group,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 3,
    );
    await FileDownloader().enqueue(task);
    return task.taskId;
  }

  /// Enqueue a background binary upload of [localFilePath] to [uploadUrl].
  Future<String> upload({
    required Uri uploadUrl,
    required String token,
    required String localFilePath,
  }) async {
    final task = UploadTask(
      url: uploadUrl.toString(),
      filePath: localFilePath,
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

  /// Stream of progress/status updates for the UI to listen to.
  Stream<TaskUpdate> get updates => FileDownloader().updates;
}
