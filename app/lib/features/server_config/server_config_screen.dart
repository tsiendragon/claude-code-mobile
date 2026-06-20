import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../core/config/server_config.dart';
import '../../core/config/server_config_controller.dart';
import '../../core/config/url_validation.dart';
import '../sessions/conversation_list_screen.dart';

class ServerConfigScreen extends StatefulWidget {
  const ServerConfigScreen({super.key});

  @override
  State<ServerConfigScreen> createState() => _ServerConfigScreenState();
}

class _ServerConfigScreenState extends State<ServerConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  final Map<ConnectionMode, _ConnectionDraft> _drafts = {};
  ConnectionMode _selectedMode = ConnectionMode.direct;
  bool _allowPrivateWs = false;
  bool _tokenObscured = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<ServerConfigController>();
    _initializeDrafts(controller);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ServerConfigController>();
    final savedProfiles = _savedProfiles(controller);
    final validation = validateServerUrl(
      _urlController.text,
      allowPrivateWs: _effectiveAllowPrivateWs,
      connectionMode: _selectedMode,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Connection mode',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ConnectionMode>(
                    segments: const [
                      ButtonSegment(
                        value: ConnectionMode.direct,
                        label: Text('Direct'),
                      ),
                      ButtonSegment(
                        value: ConnectionMode.tailscale,
                        label: Text('Tailscale'),
                      ),
                      ButtonSegment(
                        value: ConnectionMode.wireguard,
                        label: Text('WireGuard'),
                      ),
                    ],
                    selected: {_selectedMode},
                    onSelectionChanged: _selectMode,
                  ),
                  const SizedBox(height: 12),
                  if (savedProfiles.isNotEmpty) ...[
                    _SavedProfileChoices(
                      profiles: savedProfiles,
                      selectedMode: _selectedMode,
                      onSelected: (mode) => _selectMode({mode}),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _ModeNotice(mode: _selectedMode),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: 'Server URL',
                      hintText: _urlHint(_selectedMode),
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: IconButton(
                        tooltip: 'Paste URL',
                        icon: const Icon(Icons.content_paste),
                        onPressed: () => _pasteInto(_urlController),
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final result = validateServerUrl(
                        value ?? '',
                        allowPrivateWs: _effectiveAllowPrivateWs,
                        connectionMode: _selectedMode,
                      );
                      return result.error;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _tokenController,
                    decoration: InputDecoration(
                      labelText: 'Token',
                      prefixIcon: const Icon(Icons.key),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Paste token',
                            icon: const Icon(Icons.content_paste),
                            onPressed: () => _pasteInto(_tokenController),
                          ),
                          IconButton(
                            tooltip:
                                _tokenObscured ? 'Show token' : 'Hide token',
                            icon: Icon(
                              _tokenObscured
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () {
                              setState(() => _tokenObscured = !_tokenObscured);
                            },
                          ),
                        ],
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: _tokenObscured,
                    validator: (value) {
                      if ((value ?? '').trim().isEmpty) {
                        return 'Token is required.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  if (_selectedMode == ConnectionMode.direct)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow private ws://'),
                      subtitle: const Text(
                        'For localhost or trusted LAN addresses only.',
                      ),
                      value: _allowPrivateWs,
                      onChanged: (value) {
                        setState(() => _allowPrivateWs = value);
                      },
                    ),
                  if (validation.isValid &&
                      validation.risk == ServerUrlRisk.privateNetwork)
                    const _InlineNotice(
                      icon: Icons.warning_amber,
                      text: 'Private LAN ws:// is allowed. Avoid public Wi-Fi.',
                    ),
                  if (validation.isValid &&
                      validation.risk == ServerUrlRisk.tailscale)
                    const _InlineNotice(
                      icon: Icons.vpn_lock,
                      text: 'Tailscale ws:// requires the phone VPN to be on.',
                    ),
                  if (controller.error != null) ...[
                    const SizedBox(height: 8),
                    _InlineNotice(
                      icon: Icons.error_outline,
                      text: controller.error!,
                      isError: true,
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: controller.isTesting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: const Text('Connect and save'),
                    onPressed: controller.isTesting ? null : _connectAndSave,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.save),
                    label: const Text('Save without testing'),
                    onPressed: controller.isTesting ? null : _save,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const _AppVersionFooter(),
          ],
        ),
      ),
    );
  }

  Map<ConnectionMode, ServerConfig> _savedProfiles(
    ServerConfigController controller,
  ) {
    return {
      for (final mode in ConnectionMode.values)
        if (controller.profileFor(mode)?.config != null)
          mode: controller.profileFor(mode)!.config!,
    };
  }

  Future<void> _pasteInto(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() => controller.text = text);
  }

  Future<void> _connectAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await context.read<ServerConfigController>().testConnection(
          serverUrl: _urlController.text,
          token: _tokenController.text,
          allowPrivateWs: _effectiveAllowPrivateWs,
          connectionMode: _selectedMode,
        );
    if (!mounted || !ok) return;
    await _save();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await context.read<ServerConfigController>().save(
          serverUrl: _urlController.text,
          token: _tokenController.text,
          allowPrivateWs: _effectiveAllowPrivateWs,
          connectionMode: _selectedMode,
        );
    if (!mounted || !ok) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const ConversationListScreen(),
      ),
    );
  }

  bool get _effectiveAllowPrivateWs {
    return _selectedMode == ConnectionMode.direct ? _allowPrivateWs : true;
  }

  void _initializeDrafts(ServerConfigController controller) {
    if (_initialized) return;
    for (final mode in ConnectionMode.values) {
      final profile = controller.profileFor(mode);
      final config = profile?.config;
      _drafts[mode] = _ConnectionDraft(
        serverUrl: config?.serverUrl.toString() ?? _defaultServerUrl(mode),
        token: profile?.token ?? '',
        allowPrivateWs: config?.allowPrivateWs ?? false,
      );
    }

    _selectedMode = controller.activeMode;
    _applyDraft(_drafts[_selectedMode] ?? const _ConnectionDraft());
    _initialized = true;
  }

  void _selectMode(Set<ConnectionMode> modes) {
    if (modes.isEmpty) return;
    setState(() {
      _storeCurrentDraft();
      _selectedMode = modes.first;
      _applyDraft(_drafts[_selectedMode] ?? const _ConnectionDraft());
    });
  }

  void _storeCurrentDraft() {
    _drafts[_selectedMode] = _ConnectionDraft(
      serverUrl: _urlController.text,
      token: _tokenController.text,
      allowPrivateWs: _allowPrivateWs,
    );
  }

  void _applyDraft(_ConnectionDraft draft) {
    _urlController.text = draft.serverUrl;
    _tokenController.text = draft.token;
    _allowPrivateWs = draft.allowPrivateWs;
  }
}

class _ConnectionDraft {
  const _ConnectionDraft({
    this.serverUrl = '',
    this.token = '',
    this.allowPrivateWs = false,
  });

  final String serverUrl;
  final String token;
  final bool allowPrivateWs;
}

class _ModeNotice extends StatelessWidget {
  const _ModeNotice({required this.mode});

  final ConnectionMode mode;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case ConnectionMode.direct:
        return const _InlineNotice(
          icon: Icons.lan_outlined,
          text: 'Use wss:// for public servers, or trusted LAN ws://.',
        );
      case ConnectionMode.tailscale:
        return const _InlineNotice(
          icon: Icons.vpn_lock,
          text: 'Tailscale must be connected before testing.',
        );
      case ConnectionMode.wireguard:
        return const _InlineNotice(
          icon: Icons.key,
          text: 'WireGuard must be connected before testing.',
        );
    }
  }
}

class _SavedProfileChoices extends StatelessWidget {
  const _SavedProfileChoices({
    required this.profiles,
    required this.selectedMode,
    required this.onSelected,
  });

  final Map<ConnectionMode, ServerConfig> profiles;
  final ConnectionMode selectedMode;
  final ValueChanged<ConnectionMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in profiles.entries)
          ChoiceChip(
            avatar: Icon(_profileIcon(entry.key), size: 16),
            label: Text(
              '${connectionModeLabel(entry.key)} · ${entry.value.serverUrl.host}',
              overflow: TextOverflow.ellipsis,
            ),
            selected: selectedMode == entry.key,
            onSelected: (_) => onSelected(entry.key),
          ),
      ],
    );
  }

  IconData _profileIcon(ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.direct:
        return Icons.lan_outlined;
      case ConnectionMode.tailscale:
        return Icons.vpn_lock;
      case ConnectionMode.wireguard:
        return Icons.key;
    }
  }
}

/// Pre-filled server URL when there is no saved profile for [mode]. Direct mode
/// defaults to the public ccm endpoint so a fresh install can connect with just
/// a token; the VPN modes have no sensible default address.
String _defaultServerUrl(ConnectionMode mode) {
  return mode == ConnectionMode.direct ? 'wss://ccm.tsien.space/ws' : '';
}

String _urlHint(ConnectionMode mode) {
  switch (mode) {
    case ConnectionMode.direct:
      return 'wss://ccm.tsien.space/ws';
    case ConnectionMode.tailscale:
      return 'ws://100.67.213.108:8900/ws';
    case ConnectionMode.wireguard:
      return 'ws://10.8.0.1:8900/ws';
  }
}

class _AppVersionFooter extends StatefulWidget {
  const _AppVersionFooter();

  @override
  State<_AppVersionFooter> createState() => _AppVersionFooterState();
}

class _AppVersionFooterState extends State<_AppVersionFooter> {
  late final Future<PackageInfo> _infoFuture = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    return FutureBuilder<PackageInfo>(
      future: _infoFuture,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final label = info == null
            ? 'Version …'
            : '${info.appName} v${info.version} (build ${info.buildNumber})';
        return Center(
          child: InkWell(
            onTap: info == null ? null : () => _copy(label),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 14, color: color),
                  const SizedBox(width: 6),
                  Text(label, style: style),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _copy(String label) async {
    await Clipboard.setData(ClipboardData(text: label));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Version copied')),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.secondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color),
          ),
        ),
      ],
    );
  }
}
