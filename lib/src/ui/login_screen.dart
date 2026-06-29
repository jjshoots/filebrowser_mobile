import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';

/// First-run setup: enter server URL + credentials. After a successful login
/// they're stored securely and future opens use the biometric lock screen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await context.read<AuthController>().beginSetup(
          baseUrl: _url.text,
          username: _user.text,
          password: _pass.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final busy = auth.stage == AuthStage.busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Connect to File Browser')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: _url,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'https://files.example.com',
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _user,
                    decoration: const InputDecoration(labelText: 'Username'),
                    autocorrect: false,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(
                            _obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 24),
                  if (auth.error != null) ...[
                    Text(auth.error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy ? null : _submit,
                      child: busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown on subsequent launches: a single button to unlock with biometrics.
class LockScreen extends StatelessWidget {
  const LockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final busy = auth.stage == AuthStage.busy;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 64),
            const SizedBox(height: 16),
            const Text('File Browser is locked'),
            const SizedBox(height: 24),
            if (auth.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(auth.error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed:
                  busy ? null : () => context.read<AuthController>().unlockWithBiometrics(),
              icon: const Icon(Icons.fingerprint),
              label: const Text('Unlock'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => context.read<AuthController>().signOut(forget: true),
              child: const Text('Use a different server'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown after login when the server exposes several sources and none is
/// remembered: a simple list to pick the one to browse. The choice is persisted
/// (see [AuthController.selectSource]) and restored on later launches.
class SourceSelectScreen extends StatelessWidget {
  const SourceSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final sources = auth.availableSources;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a source')),
      body: ListView.separated(
        itemCount: sources.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: Text(sources[i]),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.read<AuthController>().selectSource(sources[i]),
        ),
      ),
    );
  }
}
