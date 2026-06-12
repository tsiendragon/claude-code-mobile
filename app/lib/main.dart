import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/config/server_config_controller.dart';
import 'core/secure_storage/secure_config_store.dart';
import 'features/approvals/approval_notification_controller.dart';
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
  final approvalNotifications = ApprovalNotificationController(
    client: client,
    sessions: sessionController,
  );
  unawaited(approvalNotifications.initialize());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: configController),
        ChangeNotifierProvider.value(value: sessionController),
        ChangeNotifierProvider.value(value: client),
        Provider<ApprovalNotificationController>.value(
          value: approvalNotifications,
        ),
      ],
      child: const CcmApp(),
    ),
  );
}
