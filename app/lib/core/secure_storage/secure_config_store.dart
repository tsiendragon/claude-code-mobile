import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/server_config.dart';

class SavedConfig {
  const SavedConfig({this.config, this.token});

  final ServerConfig? config;
  final String? token;
}

class SecureConfigStore {
  SecureConfigStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _serverUrlKey = 'server_url';
  static const _allowPrivateWsKey = 'allow_private_ws';
  static const _tokenKey = 'token';

  final FlutterSecureStorage _storage;

  Future<SavedConfig> read() async {
    final serverUrl = await _storage.read(key: _serverUrlKey);
    final allowPrivateWs = await _storage.read(key: _allowPrivateWsKey);
    final token = await _storage.read(key: _tokenKey);

    if (serverUrl == null) {
      return SavedConfig(token: token);
    }

    return SavedConfig(
      config: ServerConfig(
        serverUrl: Uri.parse(serverUrl),
        allowPrivateWs: allowPrivateWs == 'true',
      ),
      token: token,
    );
  }

  Future<void> write({
    required ServerConfig config,
    required String token,
  }) async {
    await _storage.write(key: _serverUrlKey, value: config.serverUrl.toString());
    await _storage.write(
      key: _allowPrivateWsKey,
      value: config.allowPrivateWs.toString(),
    );
    await _storage.write(key: _tokenKey, value: token);
  }
}
