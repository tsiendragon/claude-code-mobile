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
  ConnectionMode _activeMode = ConnectionMode.direct;
  Map<ConnectionMode, SavedConnectionProfile> _profiles =
      const <ConnectionMode, SavedConnectionProfile>{};
  String? _error;
  bool _isTesting = false;

  ServerConfig? get config => _config;
  String? get token => _token;
  ConnectionMode get activeMode => _activeMode;
  SavedConnectionProfile? profileFor(ConnectionMode mode) => _profiles[mode];
  String? get error => _error;
  bool get isTesting => _isTesting;

  Future<void> load() async {
    final saved = await _secureStore.read();
    _activeMode = saved.activeMode;
    _profiles = saved.profiles;
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
    required ConnectionMode connectionMode,
  }) async {
    _error = null;
    final effectiveAllowPrivateWs =
        connectionMode == ConnectionMode.direct ? allowPrivateWs : true;
    final validation = validateServerUrl(
      serverUrl,
      allowPrivateWs: effectiveAllowPrivateWs,
      connectionMode: connectionMode,
    );
    if (!validation.isValid) {
      _error = validation.error;
      notifyListeners();
      return false;
    }

    final config = ServerConfig(
      serverUrl: Uri.parse(serverUrl.trim()),
      allowPrivateWs: effectiveAllowPrivateWs,
      connectionMode: connectionMode,
    );
    await _secureStore.write(config: config, token: token.trim());
    _activeMode = connectionMode;
    _config = config;
    _token = token.trim();
    _profiles = Map.unmodifiable({
      ..._profiles,
      connectionMode: SavedConnectionProfile(config: config, token: _token),
    });
    _client.configure(config: config, token: _token!);
    notifyListeners();
    return true;
  }

  Future<bool> testConnection({
    required String serverUrl,
    required String token,
    required bool allowPrivateWs,
    required ConnectionMode connectionMode,
  }) async {
    _error = null;
    _isTesting = true;
    notifyListeners();

    final effectiveAllowPrivateWs =
        connectionMode == ConnectionMode.direct ? allowPrivateWs : true;
    final validation = validateServerUrl(
      serverUrl,
      allowPrivateWs: effectiveAllowPrivateWs,
      connectionMode: connectionMode,
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
        allowPrivateWs: effectiveAllowPrivateWs,
        connectionMode: connectionMode,
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
