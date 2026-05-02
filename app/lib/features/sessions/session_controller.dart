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
    required String cwd,
  }) async {
    try {
      final sessionId = await _client.runSession(name: name, cwd: cwd);
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
