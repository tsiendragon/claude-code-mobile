import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/server_config.dart';
import '../config/url_validation.dart';

class SavedConfig {
  const SavedConfig({
    this.config,
    this.token,
    this.activeMode = ConnectionMode.direct,
    this.profiles = const <ConnectionMode, SavedConnectionProfile>{},
  });

  final ServerConfig? config;
  final String? token;
  final ConnectionMode activeMode;
  final Map<ConnectionMode, SavedConnectionProfile> profiles;
}

class SavedConnectionProfile {
  const SavedConnectionProfile({this.config, this.token});

  final ServerConfig? config;
  final String? token;
}

class SecureConfigStore {
  SecureConfigStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _serverUrlKey = 'server_url';
  static const _allowPrivateWsKey = 'allow_private_ws';
  static const _tokenKey = 'token';
  static const _activeModeKey = 'active_connection_mode';

  final FlutterSecureStorage _storage;

  Future<SavedConfig> read() async {
    final profiles = <ConnectionMode, SavedConnectionProfile>{};
    for (final mode in ConnectionMode.values) {
      final profile = await _readProfile(mode);
      if (profile.config != null || profile.token != null) {
        profiles[mode] = profile;
      }
    }

    final legacy = await _readLegacyProfile();
    var activeMode = _parseMode(await _storage.read(key: _activeModeKey));
    if (legacy.config != null || legacy.token != null) {
      activeMode ??= legacy.config == null
          ? ConnectionMode.direct
          : _inferMode(legacy.config!.serverUrl);
      profiles.putIfAbsent(activeMode, () => legacy);
    }

    activeMode ??= ConnectionMode.direct;
    final active = profiles[activeMode];
    return SavedConfig(
      config: active?.config,
      token: active?.token,
      activeMode: activeMode,
      profiles: Map.unmodifiable(profiles),
    );
  }

  Future<void> write({
    required ServerConfig config,
    required String token,
  }) async {
    final mode = config.connectionMode;
    await _storage.write(key: _activeModeKey, value: mode.name);
    await _storage.write(
      key: _modeKey(_serverUrlKey, mode),
      value: config.serverUrl.toString(),
    );
    await _storage.write(
      key: _modeKey(_allowPrivateWsKey, mode),
      value: config.allowPrivateWs.toString(),
    );
    await _storage.write(key: _modeKey(_tokenKey, mode), value: token);

    await _storage.write(
        key: _serverUrlKey, value: config.serverUrl.toString());
    await _storage.write(
      key: _allowPrivateWsKey,
      value: config.allowPrivateWs.toString(),
    );
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<SavedConnectionProfile> _readProfile(ConnectionMode mode) async {
    final serverUrl = await _storage.read(key: _modeKey(_serverUrlKey, mode));
    final allowPrivateWs =
        await _storage.read(key: _modeKey(_allowPrivateWsKey, mode));
    final token = await _storage.read(key: _modeKey(_tokenKey, mode));
    if (serverUrl == null) return SavedConnectionProfile(token: token);
    return SavedConnectionProfile(
      config: ServerConfig(
        serverUrl: Uri.parse(serverUrl),
        allowPrivateWs: allowPrivateWs == 'true',
        connectionMode: mode,
      ),
      token: token,
    );
  }

  Future<SavedConnectionProfile> _readLegacyProfile() async {
    final serverUrl = await _storage.read(key: _serverUrlKey);
    final allowPrivateWs = await _storage.read(key: _allowPrivateWsKey);
    final token = await _storage.read(key: _tokenKey);
    if (serverUrl == null) return SavedConnectionProfile(token: token);
    final mode = _inferMode(Uri.parse(serverUrl));
    return SavedConnectionProfile(
      config: ServerConfig(
        serverUrl: Uri.parse(serverUrl),
        allowPrivateWs: allowPrivateWs == 'true',
        connectionMode: mode,
      ),
      token: token,
    );
  }
}

String _modeKey(String base, ConnectionMode mode) => '${base}_${mode.name}';

ConnectionMode? _parseMode(String? value) {
  if (value == null) return null;
  for (final mode in ConnectionMode.values) {
    if (mode.name == value) return mode;
  }
  return null;
}

ConnectionMode _inferMode(Uri uri) {
  if (uri.scheme == 'ws' &&
      validateServerUrl(uri.toString(), allowPrivateWs: true).risk ==
          ServerUrlRisk.tailscale) {
    return ConnectionMode.tailscale;
  }
  return ConnectionMode.direct;
}
