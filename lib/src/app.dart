import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth/auth_controller.dart';
import 'transfers/transfer_service.dart';
import 'ui/browser_screen.dart';
import 'ui/login_screen.dart';

class FileBrowserApp extends StatelessWidget {
  const FileBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<TransferService>(create: (_) => TransferService()..init()),
        ChangeNotifierProvider<AuthController>(
          create: (_) => AuthController()..bootstrap(),
        ),
      ],
      child: MaterialApp(
        title: 'File Browser',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const _AuthGate(),
      ),
    );
  }
}

/// Routes between setup, lock, and the browser based on [AuthStage].
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final stage = context.watch<AuthController>().stage;
    switch (stage) {
      case AuthStage.needsSetup:
        return const LoginScreen();
      case AuthStage.locked:
        return const LockScreen();
      case AuthStage.authenticated:
        return const BrowserScreen();
      case AuthStage.busy:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
    }
  }
}
