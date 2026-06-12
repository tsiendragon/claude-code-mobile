import 'package:flutter/foundation.dart';

import '../../protocol/client.dart';
import '../../protocol/models.dart';

class SessionController extends ChangeNotifier {
  SessionController({required BridgeClient client}) : _client = client;

  final BridgeClient _client;

  List<SessionSummary> _sessions = const [];
  bool _isLoading = false;
  String? _error;

  List<SessionSummary> get sessions => _sessions;
  bool get isLoading => _isLoading;
  String? get error => _error;
  SessionSummary? sessionById(String sessionId) {
    for (final session in _sessions) {
      if (session.sessionId == sessionId) return session;
    }
    return null;
  }

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _sessions = await _client.listSessions();
    } on BridgeException catch (error) {
      _error = error.message;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<String?> createSession({
    required String name,
    SessionBackend backend = SessionBackend.claude,
    String? cwd,
    String? workspaceId,
    bool skipPermissions = false,
  }) async {
    try {
      final sessionId = await _client.runSession(
        name: name,
        backend: backend,
        cwd: cwd,
        workspaceId: workspaceId,
        skipPermissions: skipPermissions,
      );
      await load();
      return sessionId;
    } on BridgeException catch (error) {
      _error = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<void> kill(String sessionId) async {
    try {
      await _client.killSession(sessionId);
      await load();
    } on BridgeException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }
}
