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
            _ConnectionBanner(
              state: client.state,
              error: client.lastError,
              onReconnect: _reconnect,
              onSettings: _openServerSettings,
            ),
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
                onKill: () => _confirmKill(session),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _reconnect() async {
    try {
      await context.read<BridgeClient>().connect();
      if (mounted) await context.read<SessionController>().load();
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  void _openServerSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ServerConfigScreen(),
      ),
    );
  }

  Future<void> _showCreateSessionDialog() async {
    final created = await showDialog<String?>(
      context: context,
      builder: (_) => const _CreateSessionDialog(),
    );
    if (!mounted || created == null || created.isEmpty) return;

    final sessions = context.read<SessionController>().sessions;
    SessionSummary? session;
    for (final candidate in sessions) {
      if (candidate.sessionId == created) {
        session = candidate;
        break;
      }
    }
    final selectedSession = session;
    if (selectedSession != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(session: selectedSession),
        ),
      );
    }
  }

  Future<void> _confirmKill(SessionSummary session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kill session?'),
        content: Text(
          [
            session.name,
            if (session.cwd != null && session.cwd!.isNotEmpty) session.cwd!,
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Kill'),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<SessionController>().kill(session.sessionId);
    }
  }
}

enum _WorkspaceMode { existing, create }

class _CreateSessionDialog extends StatefulWidget {
  const _CreateSessionDialog();

  @override
  State<_CreateSessionDialog> createState() => _CreateSessionDialogState();
}

class _CreateSessionDialogState extends State<_CreateSessionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _sessionNameController = TextEditingController();
  final _workspaceNameController = TextEditingController();
  final _cwdController = TextEditingController();

  SessionBackend _selectedBackend = SessionBackend.claude;
  _WorkspaceMode _workspaceMode = _WorkspaceMode.existing;
  List<WorkspaceSummary> _workspaces = const [];
  String? _selectedWorkspaceId;
  bool _useManualPath = false;
  bool _showAdvanced = false;
  bool _isLoadingWorkspaces = true;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWorkspaces());
  }

  @override
  void dispose() {
    _sessionNameController.dispose();
    _workspaceNameController.dispose();
    _cwdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New session'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<SessionBackend>(
                initialValue: _selectedBackend,
                decoration: const InputDecoration(
                  labelText: 'Agent',
                  prefixIcon: Icon(Icons.smart_toy_outlined),
                ),
                items: const [
                  DropdownMenuItem(
                    value: SessionBackend.claude,
                    child: Text('Claude Code'),
                  ),
                  DropdownMenuItem(
                    value: SessionBackend.codex,
                    child: Text('Codex'),
                  ),
                  DropdownMenuItem(
                    value: SessionBackend.opencode,
                    child: Text('Opencode'),
                  ),
                  DropdownMenuItem(
                    value: SessionBackend.cursor,
                    child: Text('Cursor'),
                  ),
                ],
                onChanged: _isSubmitting
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _selectedBackend = value);
                      },
              ),
              const SizedBox(height: 12),
              if (_isLoadingWorkspaces)
                const LinearProgressIndicator()
              else
                _buildTargetField(),
              const SizedBox(height: 12),
              TextFormField(
                controller: _sessionNameController,
                decoration: const InputDecoration(
                  labelText: 'Session name (optional)',
                  prefixIcon: Icon(Icons.terminal),
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.length > 80) return 'Use 80 characters or fewer.';
                  return null;
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      if (_useManualPath && _workspaces.isEmpty)
                        TextButton.icon(
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry workspaces'),
                          onPressed:
                              _isSubmitting ? null : () => _loadWorkspaces(),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          icon: _isSubmitting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: const Text('Create'),
          onPressed:
              _isSubmitting || _isLoadingWorkspaces ? null : _createSession,
        ),
      ],
    );
  }

  Widget _buildTargetField() {
    final selected = _selectedWorkspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_useManualPath) ...[
          ToggleButtons(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 112),
            isSelected: [
              _workspaceMode == _WorkspaceMode.existing,
              _workspaceMode == _WorkspaceMode.create,
            ],
            onPressed: _isSubmitting
                ? null
                : (index) {
                    setState(() {
                      _workspaceMode = _WorkspaceMode.values[index];
                      if (_workspaceMode == _WorkspaceMode.create) {
                        _selectedWorkspaceId = null;
                      } else if (_workspaces.isNotEmpty) {
                        _selectedWorkspaceId ??= _workspaces.first.id;
                      }
                    });
                  },
            children: const [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_open, size: 18),
                  SizedBox(width: 6),
                  Text('Existing'),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.create_new_folder, size: 18),
                  SizedBox(width: 6),
                  Text('New'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_workspaceMode == _WorkspaceMode.existing)
            DropdownButtonFormField<String>(
              initialValue: _selectedWorkspaceId,
              items: [
                for (final workspace in _workspaces)
                  DropdownMenuItem(
                    value: workspace.id,
                    child: Text(
                      workspace.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              decoration: const InputDecoration(
                labelText: 'Workspace',
                prefixIcon: Icon(Icons.folder_open),
              ),
              validator: (_) => _selectedWorkspaceId == null
                  ? 'Choose or create a workspace.'
                  : null,
              onChanged: _isSubmitting
                  ? null
                  : (value) => setState(() => _selectedWorkspaceId = value),
            )
          else
            TextFormField(
              controller: _workspaceNameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Project folder',
                prefixIcon: Icon(Icons.create_new_folder),
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return 'Folder name is required.';
                if (text.length > 80) return 'Use 80 characters or fewer.';
                if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(text)) {
                  return 'Use letters, numbers, dots, dashes, or underscores.';
                }
                return null;
              },
            ),
          const SizedBox(height: 8),
          _PathPreview(
            icon: Icons.folder,
            label: _workspaceMode == _WorkspaceMode.existing
                ? 'Server path'
                : 'Creates under server workspace root',
            value: _workspaceMode == _WorkspaceMode.existing
                ? selected?.path
                : '<workspace root>/${_workspaceNamePreview()}',
          ),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced path'),
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: _showAdvanced,
          onExpansionChanged: (expanded) {
            setState(() => _showAdvanced = _useManualPath || expanded);
          },
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use a server path'),
              subtitle: const Text('Must be inside the server allowed paths.'),
              value: _useManualPath,
              onChanged: _isSubmitting
                  ? null
                  : (value) {
                      setState(() {
                        _useManualPath = value;
                        if (value) _showAdvanced = true;
                      });
                    },
            ),
          ],
        ),
        if (_useManualPath)
          TextFormField(
            controller: _cwdController,
            decoration: const InputDecoration(
              labelText: 'Working directory',
              prefixIcon: Icon(Icons.edit_location_alt),
            ),
            validator: (value) {
              final text = (value ?? '').trim();
              if (!_useManualPath) return null;
              if (text.isEmpty) return 'Working directory is required.';
              if (!text.startsWith('/') &&
                  !text.startsWith('~/') &&
                  text != '~') {
                return 'Use /path or ~/path.';
              }
              return null;
            },
          ),
      ],
    );
  }

  Future<void> _loadWorkspaces() async {
    setState(() {
      _isLoadingWorkspaces = true;
      _error = null;
    });

    try {
      final workspaces = await context.read<BridgeClient>().listWorkspaces();
      if (!mounted) return;
      setState(() {
        _workspaces = workspaces;
        _selectedWorkspaceId = workspaces.isEmpty ? null : workspaces.first.id;
        if (workspaces.isEmpty) _workspaceMode = _WorkspaceMode.create;
        _useManualPath = false;
        _showAdvanced = false;
      });
    } on BridgeException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _useManualPath = true;
        _showAdvanced = true;
      });
    } finally {
      if (mounted) {
        setState(() => _isLoadingWorkspaces = false);
      }
    }
  }

  Future<void> _createSession() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      String? workspaceId;
      String? cwd;
      final bridgeClient = context.read<BridgeClient>();
      final sessionController = context.read<SessionController>();

      if (_useManualPath) {
        cwd = _cwdController.text.trim();
      } else {
        switch (_workspaceMode) {
          case _WorkspaceMode.existing:
            workspaceId = _selectedWorkspaceId;
            break;
          case _WorkspaceMode.create:
            final workspace = await bridgeClient.createWorkspace(
              _workspaceNameController.text.trim(),
            );
            workspaceId = workspace.id;
            break;
        }
      }

      final sessionId = await sessionController.createSession(
        name: _resolvedSessionName(),
        backend: _selectedBackend,
        workspaceId: workspaceId,
        cwd: cwd,
      );
      if (!mounted) return;
      if (sessionId == null || sessionId.isEmpty) {
        setState(() {
          _error = sessionController.error ?? 'Session creation failed.';
        });
        return;
      }
      Navigator.of(context).pop(sessionId);
    } on BridgeException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  WorkspaceSummary? get _selectedWorkspace {
    for (final workspace in _workspaces) {
      if (workspace.id == _selectedWorkspaceId) return workspace;
    }
    return null;
  }

  String _resolvedSessionName() {
    final explicit = _sessionNameController.text.trim();
    if (explicit.isNotEmpty) return explicit;
    if (_useManualPath) {
      final path = _cwdController.text.trim();
      final segments = path.split('/').where((segment) => segment.isNotEmpty);
      return segments.isEmpty ? 'Session' : segments.last;
    }
    if (_workspaceMode == _WorkspaceMode.create) {
      return _workspaceNameController.text.trim();
    }
    return _selectedWorkspace?.name ?? 'Session';
  }

  String _workspaceNamePreview() {
    final text = _workspaceNameController.text.trim();
    return text.isEmpty ? '<project>' : text;
  }
}

class _PathPreview extends StatelessWidget {
  const _PathPreview({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final text = value == null || value!.isEmpty ? 'No path selected' : value!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              SelectableText(
                text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.state,
    this.error,
    this.onReconnect,
    this.onSettings,
  });

  final BridgeConnectionState state;
  final String? error;
  final VoidCallback? onReconnect;
  final VoidCallback? onSettings;

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

    final connected = state == BridgeConnectionState.connected;
    final canAct = state == BridgeConnectionState.disconnected ||
        state == BridgeConnectionState.error;
    return Container(
      width: double.infinity,
      color: connected
          ? colorScheme.secondaryContainer
          : colorScheme.errorContainer,
      padding: const EdgeInsets.only(left: 16, right: 8, top: 6, bottom: 6),
      child: Row(
        children: [
          Icon(
            connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canAct) ...[
            IconButton(
              tooltip: 'Reconnect',
              icon: const Icon(Icons.refresh),
              onPressed: onReconnect,
            ),
            IconButton(
              tooltip: 'Server settings',
              icon: const Icon(Icons.settings),
              onPressed: onSettings,
            ),
          ],
        ],
      ),
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
    final badge = _statusBadgeText(session);
    final path = _shortPath(session.cwd);
    return ListTile(
      leading: Icon(_stateIcon(session.state)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              session.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (badge != null) _StatusBadge(text: badge),
        ],
      ),
      subtitle: Text(
        [
          session.state.name,
          sessionBackendLabel(session.backend),
          if (path != null) path,
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

  String? _statusBadgeText(SessionSummary session) {
    if (session.state == SessionState.approval) return 'Needs approval';
    if (session.state == SessionState.choosing) return 'Needs choice';
    if (session.needsAttention) return 'Needs attention';
    return null;
  }

  String? _shortPath(String? cwd) {
    if (cwd == null || cwd.isEmpty) return null;
    const marker = '/workspace/';
    final index = cwd.indexOf(marker);
    if (index >= 0) {
      return '~/workspace/${cwd.substring(index + marker.length)}';
    }
    final segments =
        cwd.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.length <= 3) return cwd;
    return '.../${segments.sublist(segments.length - 3).join('/')}';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
