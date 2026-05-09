import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/server_config_controller.dart';
import 'features/server_config/server_config_screen.dart';
import 'features/sessions/conversation_list_screen.dart';

class CcmApp extends StatelessWidget {
  const CcmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ccm',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1f6feb),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff58a6ff),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const _BootstrapScreen(),
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
