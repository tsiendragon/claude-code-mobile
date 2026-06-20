import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/server_config.dart';
import '../../core/config/server_config_controller.dart';
import '../../core/theme/ccm_motion.dart';
import '../../core/theme/ccm_tokens.dart';
import '../../core/theme/ccm_typography.dart';
import '../../core/utils/format_utils.dart';
import '../../protocol/client.dart';
import '../../protocol/models.dart';
import '../approvals/approval_notification_controller.dart';
import '../chat/chat_screen.dart';
import '../server_config/server_config_screen.dart';
import 'session_controller.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  SystemStats? _systemStats;
  WorkspaceSummary? _quickStartWorkspace;
  SessionBackend _quickStartBackend = SessionBackend.claude;
  bool _isLoadingSystemStats = false;
  bool _isLoadingQuickStart = false;
  bool _isQuickStarting = false;
  String? _systemStatsError;
  String? _quickStartError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        context
            .read<ApprovalNotificationController>()
            .requestPermissionIfNeeded(),
      );
      unawaited(_refreshAll());
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = context.watch<SessionController>();
    final client = context.watch<BridgeClient>();
    final serverConfig = context.watch<ServerConfigController>().config;
    final sessionSections = _sessionSections(sessions.sessions);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(child: _ConnectionDot(state: client.state)),
          ),
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
            onPressed: sessions.isLoading ? null : _refreshAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New session',
        onPressed: _showCreateSessionDialog,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () {
          unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
          return _refreshAll();
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            _ConnectionBanner(
              state: client.state,
              error: client.lastError,
              onReconnect: _reconnect,
              onSettings: _openServerSettings,
            ),
            _ConnectionProfilePanel(
              config: serverConfig,
              state: client.state,
              onSettings: _openServerSettings,
            ),
            _SystemStatsPanel(
              stats: _systemStats,
              isLoading: _isLoadingSystemStats,
              error: _systemStatsError,
              onRefresh: _loadSystemStats,
            ),
            _QuickStartPanel(
              workspace: _quickStartWorkspace,
              backend: _quickStartBackend,
              isLoading: _isLoadingQuickStart,
              isStarting: _isQuickStarting,
              error: _quickStartError,
              onStart: _quickStartSession,
              onConfigure: _showCreateSessionDialog,
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
              const _SessionListSkeleton(),
            if (!sessions.isLoading && sessions.sessions.isEmpty)
              const _SessionsEmptyState(),
            for (final section in sessionSections) ...[
              _SessionSectionHeader(section: section),
              for (final session in section.sessions)
                _SessionTile(
                  session: session,
                  onTap: () => _openSession(session),
                  onKill: () => _confirmKill(session),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _reconnect() async {
    try {
      await context.read<BridgeClient>().connect();
      if (mounted) await _refreshAll();
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      context.read<SessionController>().load(),
      _loadSystemStats(),
      _loadQuickStartTarget(),
    ]);
  }

  Future<void> _loadQuickStartTarget() async {
    if (!mounted) return;
    final client = context.read<BridgeClient>();
    setState(() {
      _isLoadingQuickStart = true;
      _quickStartError = null;
    });
    try {
      final prefs = await _SessionLaunchPrefs.load();
      final workspaces = await client.listWorkspaces();
      if (!mounted) return;
      final ordered = _orderWorkspacesByPreference(
        workspaces,
        prefs.recentWorkspaceIds,
      );
      setState(() {
        _quickStartBackend = prefs.backend;
        _quickStartWorkspace = ordered.isEmpty ? null : ordered.first;
      });
    } on BridgeException catch (error) {
      if (!mounted) return;
      setState(() {
        _quickStartWorkspace = null;
        _quickStartError = error.message;
      });
    } finally {
      if (mounted) {
        setState(() => _isLoadingQuickStart = false);
      }
    }
  }

  Future<void> _quickStartSession() async {
    final workspace = _quickStartWorkspace;
    if (workspace == null || _isQuickStarting) return;
    final sessionController = context.read<SessionController>();
    final navigator = Navigator.of(context);

    setState(() {
      _isQuickStarting = true;
      _quickStartError = null;
    });
    try {
      final sessionId = await sessionController.createSession(
        name: workspace.name,
        backend: _quickStartBackend,
        workspaceId: workspace.id,
      );
      if (!mounted) return;
      if (sessionId == null || sessionId.isEmpty) {
        setState(() {
          _quickStartError = sessionController.error ?? 'Session failed.';
        });
        return;
      }
      await _SessionLaunchPrefs.save(
        backend: _quickStartBackend,
        workspaceId: workspace.id,
      );
      final session = sessionController.sessionById(sessionId);
      if (session == null) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(session: session),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isQuickStarting = false);
      }
    }
  }

  Future<void> _loadSystemStats() async {
    if (!mounted) return;
    setState(() {
      _isLoadingSystemStats = true;
      _systemStatsError = null;
    });
    try {
      final stats = await context.read<BridgeClient>().getSystemStats();
      if (!mounted) return;
      setState(() => _systemStats = stats);
    } on BridgeException catch (error) {
      if (!mounted) return;
      setState(() => _systemStatsError = error.message);
    } finally {
      if (mounted) {
        setState(() => _isLoadingSystemStats = false);
      }
    }
  }

  void _openServerSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ServerConfigScreen(),
      ),
    );
  }

  void _openSession(SessionSummary session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(session: session),
      ),
    );
  }

  Future<void> _showCreateSessionDialog() async {
    final created = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
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

enum _SessionAction { kill }

enum _SessionSectionKind { attention, running, ready, problem, ended }

class _SessionSection {
  const _SessionSection({
    required this.kind,
    required this.title,
    required this.icon,
    required this.sessions,
  });

  final _SessionSectionKind kind;
  final String title;
  final IconData icon;
  final List<SessionSummary> sessions;
}

List<_SessionSection> _sessionSections(List<SessionSummary> sessions) {
  final buckets = <_SessionSectionKind, List<SessionSummary>>{
    for (final kind in _SessionSectionKind.values) kind: <SessionSummary>[],
  };
  for (final session in sessions) {
    buckets[_sectionKindFor(session)]!.add(session);
  }
  return [
    _buildSection(
      kind: _SessionSectionKind.attention,
      title: 'Needs attention',
      icon: Icons.priority_high,
      sessions: buckets[_SessionSectionKind.attention]!,
    ),
    _buildSection(
      kind: _SessionSectionKind.running,
      title: 'Running',
      icon: Icons.sync,
      sessions: buckets[_SessionSectionKind.running]!,
    ),
    _buildSection(
      kind: _SessionSectionKind.ready,
      title: 'Ready',
      icon: Icons.check_circle_outline,
      sessions: buckets[_SessionSectionKind.ready]!,
    ),
    _buildSection(
      kind: _SessionSectionKind.problem,
      title: 'Review',
      icon: Icons.error_outline,
      sessions: buckets[_SessionSectionKind.problem]!,
    ),
    _buildSection(
      kind: _SessionSectionKind.ended,
      title: 'Ended',
      icon: Icons.stop_circle_outlined,
      sessions: buckets[_SessionSectionKind.ended]!,
    ),
  ].where((section) => section.sessions.isNotEmpty).toList();
}

_SessionSection _buildSection({
  required _SessionSectionKind kind,
  required String title,
  required IconData icon,
  required List<SessionSummary> sessions,
}) {
  return _SessionSection(
    kind: kind,
    title: title,
    icon: icon,
    sessions: sessions,
  );
}

_SessionSectionKind _sectionKindFor(SessionSummary session) {
  if (session.needsAttention ||
      session.state == SessionState.approval ||
      session.state == SessionState.choosing) {
    return _SessionSectionKind.attention;
  }
  switch (session.state) {
    case SessionState.thinking:
      return _SessionSectionKind.running;
    case SessionState.ready:
      return _SessionSectionKind.ready;
    case SessionState.error:
    case SessionState.unknown:
      return _SessionSectionKind.problem;
    case SessionState.ended:
      return _SessionSectionKind.ended;
    case SessionState.approval:
    case SessionState.choosing:
      return _SessionSectionKind.attention;
  }
}

const _availableBackends = <SessionBackend>[
  SessionBackend.claude,
  SessionBackend.codex,
  SessionBackend.opencode,
  SessionBackend.cursor,
];

IconData _backendIcon(SessionBackend backend) {
  switch (backend) {
    case SessionBackend.claude:
      return Icons.auto_awesome;
    case SessionBackend.codex:
      return Icons.terminal;
    case SessionBackend.opencode:
      return Icons.code;
    case SessionBackend.cursor:
      return Icons.edit_note;
    case SessionBackend.unknown:
      return Icons.smart_toy_outlined;
  }
}

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
  List<RepoSummary> _repos = const [];
  List<String> _recentWorkspaceIds = const [];
  String? _selectedWorkspaceId;
  String? _selectedRepoId;
  bool _useManualPath = false;
  bool _showAdvanced = false;
  bool _isLoadingWorkspaces = true;
  bool _isSubmitting = false;
  bool _skipPermissions = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStartupState());
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
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: AnimatedPadding(
        duration: context.motion.durationOf(
          context,
          context.motion.fast,
        ),
        curve: context.motion.standardCurve,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Theme(
          data: theme.copyWith(
            visualDensity: VisualDensity.compact,
            inputDecorationTheme: theme.inputDecorationTheme.copyWith(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
                child: Row(
                  children: [
                    Icon(Icons.bolt, size: 18, color: tokens.liveWire),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'New session',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_selectedWorkspace != null &&
                            _selectedRepoId == null &&
                            !_useManualPath &&
                            _workspaceMode == _WorkspaceMode.existing) ...[
                          FilledButton.icon(
                            icon: _isSubmitting
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow, size: 18),
                            label: Text(
                              'Start in ${_selectedWorkspace!.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: _isSubmitting || _isLoadingWorkspaces
                                ? null
                                : _quickCreateSelectedWorkspace,
                          ),
                          const SizedBox(height: 18),
                        ],
                        _sectionLabel(context, 'AGENT'),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final backend in _availableBackends)
                              ChoiceChip(
                                avatar: Icon(_backendIcon(backend), size: 16),
                                label: Text(sessionBackendLabel(backend)),
                                selected: _selectedBackend == backend,
                                onSelected: _isSubmitting
                                    ? null
                                    : (_) {
                                        setState(
                                          () => _selectedBackend = backend,
                                        );
                                      },
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _sectionLabel(context, 'LOCATION'),
                        if (_isLoadingWorkspaces)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: LinearProgressIndicator(),
                          )
                        else
                          _buildTargetField(),
                        const SizedBox(height: 18),
                        _sectionLabel(context, 'DETAILS'),
                        TextFormField(
                          controller: _sessionNameController,
                          style: theme.textTheme.bodyMedium,
                          decoration: const InputDecoration(
                            labelText: 'Session name (optional)',
                            prefixIcon: Icon(Icons.terminal, size: 18),
                          ),
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.length > 80) {
                              return 'Use 80 characters or fewer.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: EdgeInsets.zero,
                          title: const Text('Advanced options'),
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(
                                'Skip permission prompts',
                                style: theme.textTheme.bodyMedium,
                              ),
                              subtitle: Text(
                                'Runs with --dangerously-skip-permissions',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              value: _skipPermissions,
                              onChanged: _isSubmitting
                                  ? null
                                  : (value) {
                                      setState(
                                        () => _skipPermissions = value,
                                      );
                                    },
                            ),
                          ],
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
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                                if (_useManualPath && _workspaces.isEmpty)
                                  TextButton.icon(
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('Retry workspaces'),
                                    onPressed: _isSubmitting
                                        ? null
                                        : () => _loadWorkspaces(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isSubmitting
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        icon: _isSubmitting
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Create'),
                        onPressed: _isSubmitting || _isLoadingWorkspaces
                            ? null
                            : _createSession,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    // Sans-serif (Inter) for comfortable reading — monospace is reserved for
    // actual code/command/diff blocks, not UI chrome.
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildTargetField() {
    final selected = _selectedWorkspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_useManualPath) ...[
          if (_repos.isNotEmpty) ...[
            Text(
              'Repos',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final repo in _repos)
                  ChoiceChip(
                    avatar: const Icon(Icons.folder_special, size: 16),
                    label: Text(repo.name, overflow: TextOverflow.ellipsis),
                    selected: _selectedRepoId == repo.id,
                    onSelected: _isSubmitting
                        ? null
                        : (selected) {
                            setState(() {
                              if (selected) {
                                _selectedRepoId = repo.id;
                                _selectedWorkspaceId = null;
                              } else {
                                _selectedRepoId = null;
                              }
                            });
                          },
                  ),
              ],
            ),
            if (_selectedRepo != null) ...[
              const SizedBox(height: 8),
              _PathPreview(
                icon: Icons.folder_special,
                label: 'Repo path',
                value: _selectedRepo!.path,
              ),
            ],
            const SizedBox(height: 12),
          ],
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
                      _selectedRepoId = null;
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
          if (_workspaceMode == _WorkspaceMode.existing &&
              _recentWorkspaces.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final workspace in _recentWorkspaces)
                  ChoiceChip(
                    avatar: const Icon(Icons.history, size: 16),
                    label: Text(
                      workspace.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _selectedWorkspaceId == workspace.id,
                    onSelected: _isSubmitting
                        ? null
                        : (_) {
                            setState(() {
                              _selectedWorkspaceId = workspace.id;
                              _selectedRepoId = null;
                            });
                          },
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
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
              validator: (_) =>
                  (_selectedWorkspaceId == null && _selectedRepoId == null)
                      ? 'Choose a repo, or pick/create a workspace.'
                      : null,
              onChanged: _isSubmitting
                  ? null
                  : (value) => setState(() {
                        _selectedWorkspaceId = value;
                        _selectedRepoId = null;
                      }),
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
                if (_selectedRepoId != null) return null;
                final text = (value ?? '').trim();
                if (text.isEmpty) return 'Folder name is required.';
                if (text.length > 80) return 'Use 80 characters or fewer.';
                if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(text)) {
                  return 'Use letters, numbers, dots, dashes, or underscores.';
                }
                return null;
              },
            ),
          if (_selectedRepo == null) ...[
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

  Future<void> _loadStartupState() async {
    final prefs = await _SessionLaunchPrefs.load();
    if (!mounted) return;
    setState(() {
      _selectedBackend = prefs.backend;
      _recentWorkspaceIds = prefs.recentWorkspaceIds;
    });
    unawaited(_loadRepos());
    await _loadWorkspaces(preferences: prefs);
  }

  Future<void> _loadRepos() async {
    try {
      final repos = await context.read<BridgeClient>().listRepos();
      if (!mounted) return;
      setState(() => _repos = repos);
    } on BridgeException {
      // Repos are an optional config convenience; ignore load failures.
    }
  }

  Future<void> _loadWorkspaces({_SessionLaunchPrefs? preferences}) async {
    final prefs = preferences ??
        _SessionLaunchPrefs(
          backend: _selectedBackend,
          recentWorkspaceIds: _recentWorkspaceIds,
        );
    setState(() {
      _isLoadingWorkspaces = true;
      _error = null;
    });

    try {
      final loaded = await context.read<BridgeClient>().listWorkspaces();
      final workspaces = _orderWorkspacesByPreference(
        loaded,
        prefs.recentWorkspaceIds,
      );
      if (!mounted) return;
      setState(() {
        _workspaces = workspaces;
        _recentWorkspaceIds = prefs.recentWorkspaceIds;
        _selectedWorkspaceId =
            _preferredWorkspaceId(workspaces, prefs.recentWorkspaceIds);
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

  String? _preferredWorkspaceId(
    List<WorkspaceSummary> workspaces,
    List<String> recentWorkspaceIds,
  ) {
    if (workspaces.isEmpty) return null;
    final ids = workspaces.map((workspace) => workspace.id).toSet();
    if (_selectedWorkspaceId != null && ids.contains(_selectedWorkspaceId)) {
      return _selectedWorkspaceId;
    }
    for (final id in recentWorkspaceIds) {
      if (ids.contains(id)) return id;
    }
    return workspaces.first.id;
  }

  Future<void> _quickCreateSelectedWorkspace() async {
    if (_selectedWorkspaceId == null) return;
    setState(() {
      _workspaceMode = _WorkspaceMode.existing;
      _useManualPath = false;
      _skipPermissions = false;
      _sessionNameController.clear();
    });
    await _createSession(validate: false);
  }

  Future<void> _createSession({bool validate = true}) async {
    if (validate && !_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      String? workspaceId;
      String? cwd;
      final bridgeClient = context.read<BridgeClient>();
      final sessionController = context.read<SessionController>();
      final navigator = Navigator.of(context);

      final selectedRepo = _selectedRepo;
      if (_useManualPath) {
        cwd = _cwdController.text.trim();
      } else if (selectedRepo != null) {
        cwd = selectedRepo.path;
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
        skipPermissions: _skipPermissions,
      );
      if (!mounted) return;
      if (sessionId == null || sessionId.isEmpty) {
        setState(() {
          _error = sessionController.error ?? 'Session creation failed.';
        });
        return;
      }
      await _SessionLaunchPrefs.save(
        backend: _selectedBackend,
        workspaceId: workspaceId,
      );
      navigator.pop(sessionId);
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

  RepoSummary? get _selectedRepo {
    for (final repo in _repos) {
      if (repo.id == _selectedRepoId) return repo;
    }
    return null;
  }

  List<WorkspaceSummary> get _recentWorkspaces {
    if (_recentWorkspaceIds.isEmpty) {
      return _workspaces.take(3).toList();
    }
    final recent = <WorkspaceSummary>[];
    for (final id in _recentWorkspaceIds) {
      for (final workspace in _workspaces) {
        if (workspace.id == id) {
          recent.add(workspace);
          break;
        }
      }
    }
    return recent.take(3).toList();
  }

  String _resolvedSessionName() {
    final explicit = _sessionNameController.text.trim();
    if (explicit.isNotEmpty) return explicit;
    if (_useManualPath) {
      final path = _cwdController.text.trim();
      final segments = path.split('/').where((segment) => segment.isNotEmpty);
      return segments.isEmpty ? 'Session' : segments.last;
    }
    final selectedRepo = _selectedRepo;
    if (selectedRepo != null) return selectedRepo.name;
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

class _QuickStartPanel extends StatelessWidget {
  const _QuickStartPanel({
    required this.workspace,
    required this.backend,
    required this.isLoading,
    required this.isStarting,
    required this.error,
    required this.onStart,
    required this.onConfigure,
  });

  final WorkspaceSummary? workspace;
  final SessionBackend backend;
  final bool isLoading;
  final bool isStarting;
  final String? error;
  final VoidCallback onStart;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final workspace = this.workspace;
    if (workspace == null && !isLoading && error == null) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      color: colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (workspace != null)
            FilledButton.icon(
              icon: isStarting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(
                'Start ${workspace.name}',
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: isStarting ? null : onStart,
            )
          else
            OutlinedButton.icon(
              icon: isLoading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(isLoading ? 'Finding workspaces' : 'New session'),
              onPressed: isLoading ? null : onConfigure,
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                workspace == null
                    ? Icons.info_outline
                    : Icons.folder_open_outlined,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  error ??
                      (workspace == null
                          ? 'Choose a workspace once; ccm will remember it.'
                          : '${sessionBackendLabel(backend)} · ${workspace.path}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: error == null
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.error,
                  ),
                ),
              ),
              TextButton(
                onPressed: isStarting ? null : onConfigure,
                child: const Text('Change'),
              ),
            ],
          ),
        ],
      ),
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
    if (connected) return const SizedBox.shrink();
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

class _ConnectionProfilePanel extends StatelessWidget {
  const _ConnectionProfilePanel({
    required this.config,
    required this.state,
    required this.onSettings,
  });

  final ServerConfig? config;
  final BridgeConnectionState state;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final config = this.config;
    if (config == null) return const SizedBox.shrink();

    final mode = config.connectionMode;
    return Material(
      color: colorScheme.surface,
      child: InkWell(
        onTap: onSettings,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(_connectionModeIcon(mode), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${connectionModeLabel(mode)} · ${_connectionStateLabel(state)}',
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      config.serverUrl.toString(),
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (mode != ConnectionMode.direct)
                      Text(
                        _vpnHint(mode),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.secondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Change connection',
                icon: const Icon(Icons.tune),
                onPressed: onSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _connectionModeIcon(ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.direct:
        return Icons.lan_outlined;
      case ConnectionMode.tailscale:
        return Icons.vpn_lock;
      case ConnectionMode.wireguard:
        return Icons.key;
    }
  }

  String _vpnHint(ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.direct:
        return '';
      case ConnectionMode.tailscale:
        return 'Tailscale must be connected on this phone.';
      case ConnectionMode.wireguard:
        return 'WireGuard must be connected on this phone.';
    }
  }

  String _connectionStateLabel(BridgeConnectionState state) {
    switch (state) {
      case BridgeConnectionState.connected:
        return 'Connected';
      case BridgeConnectionState.connecting:
        return 'Connecting';
      case BridgeConnectionState.authenticating:
        return 'Authenticating';
      case BridgeConnectionState.reconnecting:
        return 'Reconnecting';
      case BridgeConnectionState.error:
        return 'Error';
      case BridgeConnectionState.disconnected:
        return 'Disconnected';
    }
  }
}

class _SystemStatsPanel extends StatefulWidget {
  const _SystemStatsPanel({
    required this.stats,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
  });

  final SystemStats? stats;
  final bool isLoading;
  final String? error;
  final VoidCallback onRefresh;

  @override
  State<_SystemStatsPanel> createState() => _SystemStatsPanelState();
}

class _SystemStatsPanelState extends State<_SystemStatsPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stats = widget.stats;

    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
      child: stats == null
          ? Row(
              children: [
                const Icon(Icons.monitor_heart_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.error ??
                        (widget.isLoading
                            ? 'Loading server stats'
                            : 'Server stats unavailable'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh stats',
                  icon: widget.isLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: widget.isLoading ? null : widget.onRefresh,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.monitor_heart_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        stats.hostname.isEmpty
                            ? 'Server stats'
                            : stats.hostname,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh stats',
                      icon: widget.isLoading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      onPressed: widget.isLoading ? null : widget.onRefresh,
                    ),
                    IconButton(
                      tooltip: _expanded ? 'Collapse' : 'Expand',
                      icon: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                      ),
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: 6),
                  _MetricBar(
                    label: 'CPU',
                    value: stats.cpuPercent,
                    trailing: stats.cpuPercent == null
                        ? 'n/a'
                        : '${stats.cpuPercent!.toStringAsFixed(0)}%',
                  ),
                  const SizedBox(height: 8),
                  _MetricBar(
                    label: 'Memory',
                    value: stats.memory.usedPercent,
                    trailing:
                        '${formatBytes(stats.memory.usedBytes)} / ${formatBytes(stats.memory.totalBytes)}',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (stats.loadAverage.isNotEmpty)
                        'load ${stats.loadAverage.map((value) => value.toStringAsFixed(2)).join(' / ')}',
                      if (stats.cpuCount > 0) '${stats.cpuCount} CPU',
                      if (stats.uptimeSeconds > 0)
                        'up ${_formatDuration(stats.uptimeSeconds)}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFeatures: CcmTypography.tabularFigures),
                  ),
                ],
              ],
            ),
    );
  }
}

class _MetricBar extends StatelessWidget {
  const _MetricBar({
    required this.label,
    required this.value,
    required this.trailing,
  });

  final String label;
  final double? value;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final progress = value == null ? null : (value! / 100).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: LinearProgressIndicator(value: progress),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 104,
          child: Text(
            trailing,
            textAlign: TextAlign.right,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(fontFeatures: CcmTypography.tabularFigures),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The "alive" connection dot: the bridge's heartbeat in the app bar.
///
/// Reads the existing [BridgeConnectionState] only — it never drives the
/// connection. Steady `liveWire` amber when connected, a slow breathe while
/// connecting/reconnecting, error-red on failure, and a dim grey when idle.
/// Respects reduce-motion (no breathe).
class _ConnectionDot extends StatefulWidget {
  const _ConnectionDot({required this.state});

  final BridgeConnectionState state;

  @override
  State<_ConnectionDot> createState() => _ConnectionDotState();
}

class _ConnectionDotState extends State<_ConnectionDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_ConnectionDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isBreathing =>
      widget.state == BridgeConnectionState.connecting ||
      widget.state == BridgeConnectionState.authenticating ||
      widget.state == BridgeConnectionState.reconnecting;

  void _syncAnimation() {
    if (_isBreathing && !CcmMotion.reduceMotionOf(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller.stop();
    }
  }

  Color _color(BuildContext context) {
    final tokens = context.tokens;
    switch (widget.state) {
      case BridgeConnectionState.connected:
      case BridgeConnectionState.connecting:
      case BridgeConnectionState.authenticating:
      case BridgeConnectionState.reconnecting:
        return tokens.liveWire;
      case BridgeConnectionState.error:
        return tokens.connError;
      case BridgeConnectionState.disconnected:
        return Theme.of(context)
            .colorScheme
            .onSurfaceVariant
            .withValues(alpha: 0.4);
    }
  }

  String get _label {
    switch (widget.state) {
      case BridgeConnectionState.connected:
        return 'Connected';
      case BridgeConnectionState.connecting:
        return 'Connecting…';
      case BridgeConnectionState.authenticating:
        return 'Authenticating…';
      case BridgeConnectionState.reconnecting:
        return 'Reconnecting…';
      case BridgeConnectionState.error:
        return 'Connection error';
      case BridgeConnectionState.disconnected:
        return 'Disconnected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: _color(context),
        shape: BoxShape.circle,
      ),
    );
    final breathing = _isBreathing && !CcmMotion.reduceMotionOf(context);
    return Tooltip(
      message: _label,
      child: breathing
          ? FadeTransition(
              opacity: Tween<double>(begin: 0.35, end: 1).animate(
                CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
              ),
              child: dot,
            )
          : dot,
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
    final tokens = context.tokens;
    // The session needs you: carry the liveWire signal as mass (a full-height
    // left bar + faint wash), not just a marginal chip.
    final urgent = session.state == SessionState.approval ||
        session.state == SessionState.choosing ||
        session.needsAttention;
    final tile = ListTile(
      leading: Icon(
        _stateIcon(session.state),
        color: urgent ? tokens.liveWire : null,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              session.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (badge != null)
            _StatusBadge(
              text: badge,
              color: _statusBadgeColor(
                Theme.of(context).colorScheme,
                session,
              ),
            ),
        ],
      ),
      subtitle: Text(
        [
          sessionStateLabel(session.state),
          sessionBackendLabel(session.backend),
          if (session.lastActiveAt != null)
            _formatRelativeTime(session.lastActiveAt!),
          if (path != null) path,
          if (session.lastMessage != null) session.lastMessage!,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<_SessionAction>(
        tooltip: 'Session actions',
        onSelected: (action) {
          switch (action) {
            case _SessionAction.kill:
              onKill();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<_SessionAction>(
            value: _SessionAction.kill,
            enabled: session.state != SessionState.ended,
            child: const Row(
              children: [
                Icon(Icons.stop_circle_outlined, size: 18),
                SizedBox(width: 8),
                Text('Kill session'),
              ],
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
    if (!urgent) return tile;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.liveWire.withValues(alpha: 0.06),
        border: Border(left: BorderSide(color: tokens.liveWire, width: 3)),
      ),
      child: tile,
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

  Color _statusBadgeColor(ColorScheme colorScheme, SessionSummary session) {
    if (session.state == SessionState.approval ||
        session.state == SessionState.choosing) {
      return colorScheme.errorContainer;
    }
    return colorScheme.tertiaryContainer;
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

class _SessionSectionHeader extends StatelessWidget {
  const _SessionSectionHeader({required this.section});

  final _SessionSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final isAttention = section.kind == _SessionSectionKind.attention;
    final color =
        isAttention ? tokens.liveWire : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Icon(section.icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              section.title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            section.sessions.length.toString(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: CcmTypography.tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

String _formatRelativeTime(DateTime time) {
  final diff = DateTime.now().difference(time.toLocal());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final local = time.toLocal();
  return '${months[local.month - 1]} ${local.day}';
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _SessionLaunchPrefs {
  const _SessionLaunchPrefs({
    required this.backend,
    required this.recentWorkspaceIds,
  });

  static const _backendKey = 'ccm_session_backend';
  static const _recentWorkspacesKey = 'ccm_recent_workspace_ids';
  static const _maxRecentWorkspaces = 5;

  final SessionBackend backend;
  final List<String> recentWorkspaceIds;

  static Future<_SessionLaunchPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _SessionLaunchPrefs(
      backend: _parseBackend(prefs.getString(_backendKey)),
      recentWorkspaceIds: prefs
              .getStringList(_recentWorkspacesKey)
              ?.where((id) => id.trim().isNotEmpty)
              .toList() ??
          const <String>[],
    );
  }

  static Future<void> save({
    required SessionBackend backend,
    String? workspaceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backendKey, sessionBackendToWire(backend));

    final workspace = workspaceId?.trim();
    if (workspace == null || workspace.isEmpty) return;

    final recent = prefs.getStringList(_recentWorkspacesKey) ?? <String>[];
    final updated = <String>[
      workspace,
      for (final id in recent)
        if (id != workspace && id.trim().isNotEmpty) id,
    ].take(_maxRecentWorkspaces).toList();
    await prefs.setStringList(_recentWorkspacesKey, updated);
  }

  static SessionBackend _parseBackend(String? value) {
    if (value == null) return SessionBackend.claude;
    for (final backend in SessionBackend.values) {
      if (backend == SessionBackend.unknown) continue;
      if (sessionBackendToWire(backend) == value || backend.name == value) {
        return backend;
      }
    }
    return SessionBackend.claude;
  }
}

List<WorkspaceSummary> _orderWorkspacesByPreference(
  List<WorkspaceSummary> workspaces,
  List<String> recentWorkspaceIds,
) {
  if (workspaces.isEmpty || recentWorkspaceIds.isEmpty) return workspaces;
  final rank = <String, int>{
    for (var index = 0; index < recentWorkspaceIds.length; index++)
      recentWorkspaceIds[index]: index,
  };
  final ordered = List<WorkspaceSummary>.from(workspaces);
  ordered.sort((a, b) {
    final aRank = rank[a.id] ?? 9999;
    final bRank = rank[b.id] ?? 9999;
    if (aRank != bRank) return aRank.compareTo(bRank);
    return a.name.compareTo(b.name);
  });
  return ordered;
}

/// Branded empty state: a monospace wordmark over a liveWire hairline, with a
/// hint pointing at the FAB — never a bare "No sessions yet".
class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
      child: Column(
        children: [
          Text(
            'ccm',
            style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Container(width: 28, height: 2, color: tokens.liveWire),
          const SizedBox(height: 22),
          Text('No sessions yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Tap + to start a session on the remote machine.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tile-shaped shimmer placeholder shown while the first session load is in
/// flight — intentional, not a stock centred spinner. Honours reduce-motion.
class _SessionListSkeleton extends StatefulWidget {
  const _SessionListSkeleton();

  @override
  State<_SessionListSkeleton> createState() => _SessionListSkeletonState();
}

class _SessionListSkeletonState extends State<_SessionListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (CcmMotion.reduceMotionOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _bar(Color base, double width, double height, double t) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.05 + 0.05 * t),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    return Column(
      children: List<Widget>.generate(
        4,
        (_) => AnimatedBuilder(
          animation: _controller,
          builder: (context, __) {
            final t = _controller.value;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(base, 24, 24, t),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(base, 160, 14, t),
                        const SizedBox(height: 8),
                        _bar(base, double.infinity, 10, t),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
