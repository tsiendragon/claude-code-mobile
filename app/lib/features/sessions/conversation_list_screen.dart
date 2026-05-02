import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../chat/chat_screen.dart';
import '../server_config/server_config_screen.dart';
import 'session_controller.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SessionController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = context.watch<SessionController>();
    final client = context.watch<BridgeClient>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            tooltip: 'Server',
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ServerConfigScreen(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: sessions.isLoading ? null : sessions.load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New session',
        onPressed: _showCreateSessionDialog,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: sessions.load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            _ConnectionBanner(state: client.state, error: client.lastError),
            if (sessions.error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  sessions.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (sessions.isLoading && sessions.sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!sessions.isLoading && sessions.sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No sessions yet.')),
              ),
            for (final session in sessions.sessions)
              _SessionTile(
                session: session,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatScreen(session: session),
                    ),
                  );
                },
                onKill: () => sessions.kill(session.sessionId),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateSessionDialog() async {
    final nameController = TextEditingController();
    final cwdController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final created = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New session'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    prefixIcon: Icon(Icons.terminal),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Name is required.' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: cwdController,
                  decoration: const InputDecoration(
                    labelText: 'Working directory',
                    prefixIcon: Icon(Icons.folder),
                  ),
                  validator: (value) {
                    final text = (value ?? '').trim();
                    if (text.isEmpty) return 'Working directory is required.';
                    if (!text.startsWith('/')) return 'Use an absolute path.';
                    return null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Create'),
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                final sessionId =
                    await context.read<SessionController>().createSession(
                          name: nameController.text.trim(),
                          cwd: cwdController.text.trim(),
                        );
                if (context.mounted) {
                  Navigator.of(context).pop(sessionId);
                }
              },
            ),
          ],
        );
      },
    );

    nameController.dispose();
    cwdController.dispose();
    if (!mounted || created == null || created.isEmpty) return;

    final sessions = context.read<SessionController>().sessions;
    SessionSummary? session;
    for (final candidate in sessions) {
      if (candidate.sessionId == created) {
        session = candidate;
        break;
      }
    }
    if (session != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(session: session)),
      );
    }
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.state, this.error});

  final BridgeConnectionState state;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final text = switch (state) {
      BridgeConnectionState.connected => 'Connected',
      BridgeConnectionState.connecting => 'Connecting',
      BridgeConnectionState.authenticating => 'Authenticating',
      BridgeConnectionState.reconnecting => 'Reconnecting',
      BridgeConnectionState.error => error ?? 'Connection error',
      BridgeConnectionState.disconnected => 'Disconnected',
    };

    return Container(
      width: double.infinity,
      color: state == BridgeConnectionState.connected
          ? colorScheme.secondaryContainer
          : colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onTap,
    required this.onKill,
  });

  final SessionSummary session;
  final VoidCallback onTap;
  final VoidCallback onKill;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(_stateIcon(session.state)),
      title: Text(session.name),
      subtitle: Text(
        [
          session.state.name,
          if (session.cwd != null) session.cwd!,
          if (session.lastMessage != null) session.lastMessage!,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Kill session',
        icon: const Icon(Icons.close),
        onPressed: session.state == SessionState.ended ? null : onKill,
      ),
      onTap: onTap,
    );
  }

  IconData _stateIcon(SessionState state) {
    switch (state) {
      case SessionState.approval:
      case SessionState.choosing:
        return Icons.priority_high;
      case SessionState.thinking:
        return Icons.sync;
      case SessionState.ready:
        return Icons.check_circle_outline;
      case SessionState.error:
        return Icons.error_outline;
      case SessionState.ended:
        return Icons.stop_circle_outlined;
      case SessionState.unknown:
        return Icons.help_outline;
    }
  }
}
