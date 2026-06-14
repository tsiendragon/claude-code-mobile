import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/server_config_controller.dart';
import 'core/theme/ccm_motion.dart';
import 'core/theme/ccm_tokens.dart';
import 'core/theme/ccm_typography.dart';
import 'features/server_config/server_config_screen.dart';
import 'features/sessions/conversation_list_screen.dart';
import 'protocol/client.dart';
import 'protocol/models.dart';

class CcmApp extends StatefulWidget {
  const CcmApp({super.key});

  @override
  State<CcmApp> createState() => _CcmAppState();
}

class _CcmAppState extends State<CcmApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    final client = context.read<BridgeClient>();
    if (!client.isConfigured) return;
    switch (client.state) {
      case BridgeConnectionState.disconnected:
      case BridgeConnectionState.error:
      case BridgeConnectionState.reconnecting:
        unawaited(client.reconnectNow().catchError((Object _) {}));
        break;
      case BridgeConnectionState.connecting:
      case BridgeConnectionState.authenticating:
      case BridgeConnectionState.connected:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ccm',
      theme: _buildTheme(
        ColorScheme.fromSeed(
          seedColor: const Color(0xff1f6feb),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: _buildTheme(
        ColorScheme.fromSeed(
          seedColor: const Color(0xff58a6ff),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const _BootstrapScreen(),
    );
  }

  /// Builds a theme from [scheme] and registers the CCM token layer.
  ///
  /// `surfaceTint` is disabled so Material 3 stops washing elevated surfaces
  /// with the primary colour — keeping surfaces neutral so the rationed
  /// `liveWire` accent is the only chromatic event.
  ThemeData _buildTheme(ColorScheme scheme) {
    final tinted = scheme.copyWith(surfaceTint: Colors.transparent);
    return ThemeData(
      colorScheme: tinted,
      useMaterial3: true,
      extensions: <ThemeExtension<dynamic>>[
        CcmTokens.fromScheme(tinted),
        CcmTypography.standard(),
        CcmMotion.standard(),
      ],
    );
  }
}

class _BootstrapScreen extends StatefulWidget {
  const _BootstrapScreen();

  @override
  State<_BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<_BootstrapScreen> {
  late final Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = context.read<ServerConfigController>().load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final config = context.watch<ServerConfigController>().config;
        if (config == null) {
          return const ServerConfigScreen();
        }

        return const ConversationListScreen();
      },
    );
  }
}
