import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/config/server_config_controller.dart';
import 'core/secure_storage/secure_config_store.dart';
import 'features/sessions/session_controller.dart';
import 'protocol/client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final secureStore = SecureConfigStore();
  final client = BridgeClient();
  final configController = ServerConfigController(
    secureStore: secureStore,
    client: client,
  );
  final sessionController = SessionController(client: client);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: configController),
        ChangeNotifierProvider.value(value: sessionController),
        ChangeNotifierProvider.value(value: client),
      ],
      child: const CcmApp(),
    ),
  );
}
