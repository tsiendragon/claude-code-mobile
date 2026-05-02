import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  bool _allowPrivateWs = false;
  bool _tokenObscured = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<ServerConfigController>();
    final config = controller.config;
    if (config != null && _urlController.text.isEmpty) {
      _urlController.text = config.serverUrl.toString();
      _allowPrivateWs = config.allowPrivateWs;
    }
    final token = controller.token;
    if (token != null && _tokenController.text.isEmpty) {
      _tokenController.text = token;
    }
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
    final validation = validateServerUrl(
      _urlController.text,
      allowPrivateWs: _allowPrivateWs,
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
                  TextFormField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'wss://ccm.example.com/ws',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final result = validateServerUrl(
                        value ?? '',
                        allowPrivateWs: _allowPrivateWs,
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
                      suffixIcon: IconButton(
                        tooltip: _tokenObscured ? 'Show token' : 'Hide token',
                        icon: Icon(
                          _tokenObscured
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() => _tokenObscured = !_tokenObscured);
                        },
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
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow private ws://'),
                    subtitle: const Text(
                      'For localhost, RFC1918 LAN, or Tailscale URLs only.',
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
                    label: const Text('Test connection'),
                    onPressed: controller.isTesting ? null : _testConnection,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                    onPressed: _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await context.read<ServerConfigController>().testConnection(
          serverUrl: _urlController.text,
          token: _tokenController.text,
          allowPrivateWs: _allowPrivateWs,
        );
    if (!mounted || !ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connection authenticated.')),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await context.read<ServerConfigController>().save(
          serverUrl: _urlController.text,
          token: _tokenController.text,
          allowPrivateWs: _allowPrivateWs,
        );
    if (!mounted || !ok) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const ConversationListScreen(),
      ),
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
