import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../transfers/transfer_record.dart';
import '../transfers/transfer_service.dart';
import 'error_display.dart';

/// Live list of background transfers (uploads + downloads), driven by
/// [TransferService.records]. Each row shows the filename, a progress bar with
/// percentage, and the current state, plus the controls that apply to that
/// state: pause/resume (downloads only — POST uploads can't pause), cancel, and
/// retry for a failed/canceled task.
///
/// Reached from the browser app bar's transfers icon (which badges the active
/// count). Retrying refreshes the session first ([AuthController.ensureFreshSession])
/// so a long-idle transfer re-enqueues with a current token.
class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final transfers = context.read<TransferService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear finished',
            onPressed: transfers.clearFinished,
          ),
        ],
      ),
      body: StreamBuilder<List<TransferRecord>>(
        stream: transfers.records,
        initialData: transfers.current,
        builder: (context, snap) {
          final records = snap.data ?? const <TransferRecord>[];
          if (records.isEmpty) {
            return const Center(child: Text('No transfers yet'));
          }
          return ListView.separated(
            itemCount: records.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) =>
                _TransferTile(record: records[i], transfers: transfers),
          );
        },
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.record, required this.transfers});

  final TransferRecord record;
  final TransferService transfers;

  Future<void> _retry(BuildContext context) async {
    final auth = context.read<AuthController>();
    final messenger = ScaffoldMessenger.of(context);
    await auth.ensureFreshSession();
    final token = auth.client?.token;
    if (token == null) {
      showErrorSnackBar(messenger, 'Cannot retry: session expired. Sign in again.');
      return;
    }
    await transfers.retry(record, token: token);
  }

  @override
  Widget build(BuildContext context) {
    final showBar = record.isActive && record.status != TaskStatus.enqueued;
    return ListTile(
      leading: Icon(record.isUpload ? Icons.upload : Icons.download),
      title: Text(record.filename, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (showBar)
            LinearProgressIndicator(
              value: record.progress > 0 ? record.progress : null,
            ),
          const SizedBox(height: 4),
          Text(_statusLabel(record)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (record.canPause)
            IconButton(
              icon: const Icon(Icons.pause),
              tooltip: 'Pause',
              onPressed: () => transfers.pause(record),
            ),
          if (record.canResume)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Resume',
              onPressed: () => transfers.resume(record),
            ),
          if (record.canRetry)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry',
              onPressed: () => _retry(context),
            ),
          if (record.canCancel)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: () => transfers.cancel(record),
            ),
        ],
      ),
    );
  }

  String _statusLabel(TransferRecord r) {
    final pct = (r.progress.clamp(0, 1) * 100).round();
    switch (r.status) {
      case TaskStatus.enqueued:
        return 'Queued';
      case TaskStatus.running:
        return 'Transferring $pct%';
      case TaskStatus.paused:
        return 'Paused $pct%';
      case TaskStatus.waitingToRetry:
        return 'Waiting to retry…';
      case TaskStatus.complete:
        return 'Complete';
      case TaskStatus.failed:
        return 'Failed';
      case TaskStatus.notFound:
        return 'Failed (not found)';
      case TaskStatus.canceled:
        return 'Canceled';
    }
  }
}
