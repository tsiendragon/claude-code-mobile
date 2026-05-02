import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/server_config.dart';
import 'codec.dart';
import 'models.dart';

class BridgeException implements Exception {
  const BridgeException(this.message, {this.code, this.retryable = false});

  final String message;
  final String? code;
  final bool retryable;

  @override
  String toString() => 'BridgeException($code, $message)';
}

class BridgeClient extends ChangeNotifier {
  static const protocolVersion = 1;

  ServerConfig? _config;
  String? _token;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _requestCounter = 0;
  int _reconnectAttempt = 0;
  bool _closedByUser = false;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Map<String, int> _attachedSessions = {};
  final StreamController<BridgeEventEnvelope> _events =
      StreamController<BridgeEventEnvelope>.broadcast();

  BridgeConnectionState _state = BridgeConnectionState.disconnected;
  String? _lastError;

  BridgeConnectionState get state => _state;
  String? get lastError => _lastError;
  Stream<BridgeEventEnvelope> get events => _events.stream;
  bool get isConfigured => _config != null && _token != null;

  void configure({
    required ServerConfig config,
    required String token,
  }) {
    final configChanged = _config?.serverUrl != config.serverUrl ||
        _config?.allowPrivateWs != config.allowPrivateWs ||
        _token != token;
    _config = config;
    _token = token;
    if (configChanged) {
      _closedByUser = true;
      _reconnectTimer?.cancel();
      _attachedSessions.clear();
      unawaited(_teardownSocket());
      _setState(BridgeConnectionState.disconnected);
    }
  }

  Future<void> connect() async {
    final config = _config;
    final token = _token;
    if (config == null || token == null || token.isEmpty) {
      throw const BridgeException('Server URL and token are required.');
    }

    _reconnectTimer?.cancel();
    _closedByUser = true;
    await _teardownSocket();
    _closedByUser = false;
    _setState(
      _state == BridgeConnectionState.disconnected
          ? BridgeConnectionState.connecting
          : BridgeConnectionState.reconnecting,
    );

    try {
      _channel = WebSocketChannel.connect(config.serverUrl);
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onDone: _handleDisconnect,
        onError: (Object error) => _handleDisconnect(error),
      );

      _setState(BridgeConnectionState.authenticating);
      await request('auth', {
        'protocol_version': protocolVersion,
        'authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 5));

      _reconnectAttempt = 0;
      _lastError = null;
      _setState(BridgeConnectionState.connected);
      _startHeartbeat();
      await _reattachSessions();
    } catch (error) {
      await _teardownSocket();
      _lastError = error is BridgeException ? error.message : error.toString();
      _setState(BridgeConnectionState.error);
      rethrow;
    }
  }

  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    await _teardownSocket();
    _setState(BridgeConnectionState.disconnected);
  }

  @override
  void dispose() {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    unawaited(_events.close());
    super.dispose();
  }

  Future<List<SessionSummary>> listSessions() async {
    final data = await request('session.list');
    final rawSessions = data['sessions'];
    if (rawSessions is! List) return const [];

    final sessions = rawSessions
        .whereType<Map>()
        .map((raw) => SessionSummary.fromJson(Map<String, Object?>.from(raw)))
        .toList();
    sessions.sort(_compareSessions);
    return sessions;
  }

  Future<List<WorkspaceSummary>> listWorkspaces() async {
    final data = await request('workspace.list');
    final rawWorkspaces = data['workspaces'];
    if (rawWorkspaces is! List) return const [];

    final workspaces = rawWorkspaces
        .whereType<Map>()
        .map((raw) => WorkspaceSummary.fromJson(Map<String, Object?>.from(raw)))
        .toList();
    workspaces.sort((a, b) => a.name.compareTo(b.name));
    return workspaces;
  }

  Future<WorkspaceSummary> createWorkspace(String name) async {
    final data = await request('workspace.create', {'name': name});
    final rawWorkspace = data['workspace'];
    if (rawWorkspace is Map) {
      return WorkspaceSummary.fromJson(Map<String, Object?>.from(rawWorkspace));
    }
    throw const BridgeException('Bridge did not return a workspace.');
  }

  Future<ChatStateSnapshot> attachSession(String sessionId) async {
    final data = await request('session.attach', {'session_id': sessionId});
    final snapshot = ChatStateSnapshot.fromAttachResponse(data);
    _attachedSessions[sessionId] = snapshot.lastSeq;
    return snapshot;
  }

  Future<void> syncEvents(String sessionId, int afterSeq) async {
    final data = await request('events.sync', {
      'session_id': sessionId,
      'after': afterSeq,
    });
    final events = data['events'];
    if (events is List) {
      for (final raw in events.whereType<Map>()) {
        final envelope = BridgeEventEnvelope.fromJson(
          Map<String, Object?>.from(raw),
        );
        _attachedSessions[envelope.sessionId] = envelope.seq;
        _events.add(envelope);
      }
    }
  }

  Future<String> runSession({
    required String name,
    String? cwd,
    String? workspaceId,
  }) async {
    final hasWorkspaceId = workspaceId != null && workspaceId.isNotEmpty;
    final hasCwd = cwd != null && cwd.isNotEmpty;
    if (hasWorkspaceId == hasCwd) {
      throw const BridgeException(
        'Choose exactly one workspace or working directory.',
      );
    }

    final payload = <String, Object?>{
      'name': name,
      'backend': 'claude',
      if (hasWorkspaceId)
        'workspace_id': workspaceId
      else
        'cwd': cwd,
    };
    final data = await request('session.run', payload);
    return data['session_id'] as String? ?? '';
  }

  Future<void> killSession(String sessionId) async {
    await request('session.kill', {'session_id': sessionId});
    _attachedSessions.remove(sessionId);
  }

  Future<void> sendMessage({
    required String sessionId,
    required String clientMessageId,
    required String text,
  }) async {
    await request('message.send', {
      'session_id': sessionId,
      'client_msg_id': clientMessageId,
      'text': text,
    });
  }

  Future<void> approve({
    required String sessionId,
    required String approvalId,
    required String action,
    required String idempotencyKey,
  }) async {
    await request('message.approve', {
      'session_id': sessionId,
      'approval_id': approvalId,
      'action': action,
      'idempotency_key': idempotencyKey,
    });
  }

  Future<void> interrupt(String sessionId) async {
    await request('message.interrupt', {'session_id': sessionId});
  }

  Future<Map<String, Object?>> request(
    String type, [
    Map<String, Object?> data = const {},
  ]) async {
    if (_channel == null && type != 'auth') {
      await connect();
    }

    final requestId = 'req_${++_requestCounter}';
    final completer = Completer<Map<String, Object?>>();
    _pending[requestId] = completer;
    _channel!.sink.add(encodeBridgeRequest(type: type, id: requestId, data: data));
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(requestId);
        throw const BridgeException(
          'Bridge request timed out.',
          code: 'REQUEST_TIMEOUT',
          retryable: true,
        );
      },
    );
  }

  void _handleMessage(dynamic rawMessage) {
    try {
      final decoded = decodeBridgeMessage(rawMessage as String);
      if (decoded is BridgeResponse) {
        final completer = _pending.remove(decoded.id);
        if (completer == null) return;
        if (decoded.ok) {
          completer.complete(decoded.data ?? const {});
        } else {
          final error = decoded.error;
          completer.completeError(
            BridgeException(
              error?.message ?? 'Bridge request failed.',
              code: error?.code,
              retryable: error?.retryable ?? false,
            ),
          );
        }
      } else if (decoded is BridgeEventEnvelope) {
        _attachedSessions[decoded.sessionId] = decoded.seq;
        _events.add(decoded);
      }
    } catch (error) {
      _lastError = error.toString();
      notifyListeners();
    }
  }

  void _handleDisconnect([Object? error]) {
    if (error != null) {
      _lastError = error.toString();
    }
    unawaited(_teardownSocket());
    if (!_closedByUser) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _setState(BridgeConnectionState.reconnecting);
    final delaySeconds = (1 << _reconnectAttempt).clamp(1, 30).toInt();
    _reconnectAttempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      unawaited(connect().catchError((Object error) {
        _lastError = error.toString();
        _scheduleReconnect();
      }));
    });
  }

  Future<void> _reattachSessions() async {
    final sessions = Map<String, int>.from(_attachedSessions);
    for (final entry in sessions.entries) {
      try {
        final snapshot = await attachSession(entry.key);
        if (snapshot.lastSeq > entry.value) {
          await syncEvents(entry.key, entry.value);
        }
      } catch (error) {
        _lastError = error.toString();
      }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_state == BridgeConnectionState.connected) {
        unawaited(
          request('ping').catchError((Object _) => const <String, Object?>{}),
        );
      }
    });
  }

  Future<void> _teardownSocket() async {
    _heartbeatTimer?.cancel();
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await subscription?.cancel();
    if (channel != null) {
      await channel.sink.close();
    }

    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const BridgeException(
            'Bridge connection closed.',
            code: 'CONNECTION_CLOSED',
            retryable: true,
          ),
        );
      }
    }
    _pending.clear();
  }

  void _setState(BridgeConnectionState next) {
    _state = next;
    notifyListeners();
  }

  int _compareSessions(SessionSummary a, SessionSummary b) {
    final byState = _stateSortRank(a.state).compareTo(_stateSortRank(b.state));
    if (byState != 0) return byState;
    return a.name.compareTo(b.name);
  }

  int _stateSortRank(SessionState state) {
    switch (state) {
      case SessionState.approval:
      case SessionState.choosing:
        return 0;
      case SessionState.thinking:
        return 1;
      case SessionState.ready:
        return 2;
      case SessionState.error:
        return 3;
      case SessionState.ended:
        return 4;
      case SessionState.unknown:
        return 5;
    }
  }
}
