import 'package:flutter/foundation.dart';

import '../../protocol/client.dart';
import '../secure_storage/secure_config_store.dart';
import 'server_config.dart';
import 'url_validation.dart';

class ServerConfigController extends ChangeNotifier {
  ServerConfigController({
    required SecureConfigStore secureStore,
    required BridgeClient client,
  })  : _secureStore = secureStore,
        _client = client;

  final SecureConfigStore _secureStore;
  final BridgeClient _client;

  ServerConfig? _config;
  String? _token;
  String? _error;
  bool _isTesting = false;

  ServerConfig? get config => _config;
  String? get token => _token;
  String? get error => _error;
  bool get isTesting => _isTesting;

  Future<void> load() async {
    final saved = await _secureStore.read();
    _config = saved.config;
    _token = saved.token;
    if (_config != null && _token != null && _token!.isNotEmpty) {
      _client.configure(config: _config!, token: _token!);
    }
    notifyListeners();
  }

  Future<bool> save({
    required String serverUrl,
    required String token,
    required bool allowPrivateWs,
  }) async {
    _error = null;
    final validation = validateServerUrl(
      serverUrl,
      allowPrivateWs: allowPrivateWs,
    );
    if (!validation.isValid) {
      _error = validation.error;
      notifyListeners();
      return false;
    }

    final config = ServerConfig(
      serverUrl: Uri.parse(serverUrl.trim()),
      allowPrivateWs: allowPrivateWs,
    );
    await _secureStore.write(config: config, token: token.trim());
    _config = config;
    _token = token.trim();
    _client.configure(config: config, token: _token!);
    notifyListeners();
    return true;
  }

  Future<bool> testConnection({
    required String serverUrl,
    required String token,
    required bool allowPrivateWs,
  }) async {
    _error = null;
    _isTesting = true;
    notifyListeners();

    final validation = validateServerUrl(
      serverUrl,
      allowPrivateWs: allowPrivateWs,
    );
    if (!validation.isValid) {
      _error = validation.error;
      _isTesting = false;
      notifyListeners();
      return false;
    }

    final probe = BridgeClient();
    probe.configure(
      config: ServerConfig(
        serverUrl: Uri.parse(serverUrl.trim()),
        allowPrivateWs: allowPrivateWs,
      ),
      token: token.trim(),
    );

    try {
      await probe.connect();
      _error = null;
      return true;
    } on BridgeException catch (error) {
      _error = error.message;
      return false;
    } finally {
      await probe.close();
      _isTesting = false;
      notifyListeners();
    }
  }
}
