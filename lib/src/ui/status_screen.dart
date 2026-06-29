import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import '../auth/auth_controller.dart';
import 'error_display.dart';
import 'shares_screen.dart';

/// Whether disk-usage figures are meaningful. A source that is unindexed (or
/// reports no capacity) yields `total=0`, so a zero total means "unavailable"
/// rather than a full/empty disk. PURE — see `status_screen_test.dart`.
bool diskUsageAvailable(FbUsage usage) => usage.total > 0;

/// Loads server settings, degrading to `null` instead of throwing.
///
/// `GET /api/settings` is admin-only and returns 403 for normal users;
/// any failure (403, network, parse) collapses to `null` so the Status screen
/// can simply omit the server-info section. PURE-ish (no UI) — see
/// `status_screen_test.dart`.
Future<FbServerCaps?> tryLoadSettings(FileBrowserClient client) async {
  try {
    return await client.getSettings();
  } catch (_) {
    return null;
  }
}

/// Status / Settings page: disk usage, the signed-in user, and (when the user
/// is an admin) server info — plus Lock and Sign-out actions.
///
/// Disk usage is intentionally surfaced here and NOT on the main grid.
class StatusScreen extends StatefulWidget {
  const StatusScreen({
    super.key,
    required this.client,
    required this.user,
  });

  final FileBrowserClient client;
  final FbUser? user;

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  late Future<FbUsage?> _usage;
  late Future<FbServerCaps?> _settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _usage = widget.client.diskUsage();
    _settings = tryLoadSettings(widget.client);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Status')),
      body: RefreshIndicator(
        onRefresh: () async => setState(_load),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('Storage'),
            _usageCard(),
            const SizedBox(height: 24),
            _section('Account'),
            _userCard(),
            const SizedBox(height: 24),
            _section('Server'),
            _serverCard(),
            const SizedBox(height: 24),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _usageCard() {
    return FutureBuilder<FbUsage?>(
      future: _usage,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        if (snap.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: CopyableErrorView(
                message: snap.error.toString(),
                onRetry: () => setState(_load),
              ),
            ),
          );
        }
        final usage = snap.data;
        if (usage == null || !diskUsageAvailable(usage)) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.help_outline),
              title: Text('Disk usage unavailable'),
              subtitle:
                  Text('The server did not report capacity for this source.'),
            ),
          );
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: usage.usedFraction,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(height: 12),
                Text('${usage.usedHuman} of ${usage.totalHuman} used '
                    '(${(usage.usedFraction * 100).toStringAsFixed(1)}%)'),
                const SizedBox(height: 4),
                Text('${usage.freeHuman} free',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _userCard() {
    final user = widget.user;
    final perms = <String>[
      if (user?.canCreate ?? false) 'create',
      if (user?.canModify ?? false) 'modify',
    ];
    return Card(
      child: ListTile(
        leading: const Icon(Icons.person_outline),
        title: Text(user?.username.isNotEmpty == true
            ? user!.username
            : 'Unknown user'),
        subtitle: Text(perms.isEmpty
            ? 'Read-only'
            : 'Permissions: ${perms.join(', ')}'),
      ),
    );
  }

  Widget _serverCard() {
    return FutureBuilder<FbServerCaps?>(
      future: _settings,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text('Loading server info…'),
            ),
          );
        }
        final caps = snap.data;
        if (caps == null) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text('Server info unavailable'),
              subtitle: Text('Requires an administrator account.'),
            ),
          );
        }
        return Card(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(caps.name.isEmpty ? 'File Browser' : caps.name),
            subtitle: Text('Signup ${caps.signup ? 'enabled' : 'disabled'}'),
          ),
        );
      },
    );
  }

  Widget _actions(BuildContext context) {
    final auth = context.read<AuthController>();
    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SharesScreen(client: widget.client),
          )),
          icon: const Icon(Icons.link),
          label: const Text('Manage shared links'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => auth.signOut(),
          icon: const Icon(Icons.lock_outline),
          label: Text('Lock${widget.user != null ? ' (${widget.user!.username})' : ''}'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => auth.signOut(forget: true),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out & forget'),
        ),
      ],
    );
  }
}
