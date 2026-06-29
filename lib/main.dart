import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/data/preferences_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // PreferencesStore.create() is async (it awaits SharedPreferences). We resolve
  // it once here, before runApp, and inject the ready instance via
  // Provider.value in app.dart. This keeps the widget tree synchronous (no
  // FutureProvider loading gate) and matches the existing eager MultiProvider
  // bootstrap style (TransferService()..init(), AuthController()..bootstrap()).
  final prefs = await PreferencesStore.create();
  runApp(FileBrowserApp(prefs: prefs));
}
