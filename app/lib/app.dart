import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/server_config_controller.dart';
import 'core/theme/ccm_color_scheme.dart';
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
      theme: _buildTheme(ccmLightScheme()),
      darkTheme: _buildTheme(ccmDarkScheme()),
      themeMode: ThemeMode.system,
      home: const _BootstrapScreen(),
    );
  }

  /// Builds a theme from [scheme] and registers the CCM token layer.
  ///
  /// `surfaceTint` is disabled so Material 3 stops washing elevated surfaces
  /// with the primary colour — keeping surfaces neutral graphite so the
  /// rationed `liveWire` accent is the only chromatic event. Interactive
  /// elements use tight 2px tool geometry; panels/cards stay at the panel
  /// radius with a flat hairline border (no drop shadow).
  ThemeData _buildTheme(ColorScheme scheme) {
    final tokens = CcmTokens.fromScheme(scheme);
    final toolShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(2),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: scheme.surface,
      extensions: <ThemeExtension<dynamic>>[
        tokens,
        CcmTypography.standard(),
        CcmMotion.standard(),
      ],
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusPanel),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: toolShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: toolShape),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: toolShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: toolShape),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: tokens.liveWire, width: 2),
        ),
      ),
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

        final controller = context.watch<ServerConfigController>();
        final config = controller.config;
        final token = controller.token;
        // After a reinstall the URL is recovered from the backed-up mirror but
        // the token isn't (it's wiped with the KeyStore), so route to the
        // config screen — which pre-fills the URL — until a token is entered.
        if (config == null || token == null || token.isEmpty) {
          return const ServerConfigScreen();
        }

        return const ConversationListScreen();
      },
    );
  }
}
