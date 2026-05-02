enum BridgeConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  reconnecting,
  error,
}

enum SessionState {
  ready,
  thinking,
  approval,
  choosing,
  error,
  ended,
  unknown,
}

SessionState sessionStateFromWire(String? value) {
  return SessionState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => SessionState.unknown,
  );
}

class BridgeError {
  const BridgeError({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;

  factory BridgeError.fromJson(Map<String, Object?> json) {
    return BridgeError(
      code: json['code'] as String? ?? 'UNKNOWN',
      message: json['message'] as String? ?? 'Unknown error',
      retryable: json['retryable'] as bool? ?? false,
    );
  }
}

class BridgeResponse {
  const BridgeResponse({
    required this.id,
    required this.ok,
    this.data,
    this.error,
  });

  final String id;
  final bool ok;
  final Map<String, Object?>? data;
  final BridgeError? error;

  factory BridgeResponse.fromJson(Map<String, Object?> json) {
    final rawData = json['data'];
    final rawError = json['error'];
    return BridgeResponse(
      id: json['id'] as String? ?? '',
      ok: json['ok'] as bool? ?? false,
      data: rawData is Map ? Map<String, Object?>.from(rawData) : null,
      error: rawError is Map
          ? BridgeError.fromJson(Map<String, Object?>.from(rawError))
          : null,
    );
  }
}

class BridgeEventEnvelope {
  const BridgeEventEnvelope({
    required this.sessionId,
    required this.seq,
    required this.event,
  });

  final String sessionId;
  final int seq;
  final DomainEvent event;

  factory BridgeEventEnvelope.fromJson(Map<String, Object?> json) {
    final rawEvent = json['event'];
    return BridgeEventEnvelope(
      sessionId: json['session_id'] as String? ?? '',
      seq: json['seq'] as int? ?? 0,
      event: DomainEvent.fromJson(
        rawEvent is Map
            ? Map<String, Object?>.from(rawEvent)
            : const <String, Object?>{},
      ),
    );
  }
}

class DomainEvent {
  const DomainEvent({
    required this.kind,
    required this.payload,
  });

  final String kind;
  final Map<String, Object?> payload;

  factory DomainEvent.fromJson(Map<String, Object?> json) {
    return DomainEvent(
      kind: json['kind'] as String? ?? 'unknown',
      payload: json,
    );
  }
}

class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.name,
    required this.backend,
    required this.state,
    required this.lastSeq,
    this.cwd,
    this.lastMessage,
    this.needsAttention = false,
  });

  final String sessionId;
  final String name;
  final String backend;
  final SessionState state;
  final int lastSeq;
  final String? cwd;
  final String? lastMessage;
  final bool needsAttention;

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    return SessionSummary(
      sessionId: json['session_id'] as String? ??
          json['sessionId'] as String? ??
          '',
      name: json['name'] as String? ?? 'Session',
      backend: json['backend'] as String? ?? 'claude',
      state: sessionStateFromWire(json['state'] as String?),
      lastSeq: json['last_seq'] as int? ?? json['lastSeq'] as int? ?? 0,
      cwd: json['cwd'] as String?,
      lastMessage: json['last_message'] as String? ??
          json['lastMessage'] as String?,
      needsAttention: json['needs_attention'] as bool? ??
          json['needsAttention'] as bool? ??
          false,
    );
  }
}

class ChatStateSnapshot {
  const ChatStateSnapshot({
    required this.session,
    required this.items,
    required this.lastSeq,
    this.pendingApproval,
    this.latestOutputSnapshot,
    this.hasEventGap = false,
  });

  final SessionSummary session;
  final List<ChatItem> items;
  final int lastSeq;
  final PendingApproval? pendingApproval;
  final String? latestOutputSnapshot;
  final bool hasEventGap;

  factory ChatStateSnapshot.fromAttachResponse(Map<String, Object?> json) {
    final rawSession = json['session'];
    final rawItems = json['items'] ?? json['messages'];
    final rawEvents = json['recent_events'] ?? json['recentEvents'];
    final rawApproval = json['pending_approval'] ?? json['pendingApproval'];

    final session = SessionSummary.fromJson(
      rawSession is Map
          ? Map<String, Object?>.from(rawSession)
          : <String, Object?>{
              'session_id': json['session_id'],
              'name': json['name'],
              'backend': json['backend'],
              'state': json['state'],
              'last_seq': json['last_seq'],
            },
    );

    final eventItems = <ChatItem>[];
    String? latestOutputSnapshot;
    for (final event in _eventsFromJson(rawEvents)) {
      final item = ChatItem.fromEvent(event);
      if (item == null) continue;
      if (item.snapshot) {
        latestOutputSnapshot = item.text;
      } else {
        eventItems.add(item);
      }
    }

    return ChatStateSnapshot(
      session: session,
      items: rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) => ChatItem.fromJson(Map<String, Object?>.from(item)))
              .toList()
          : eventItems,
      lastSeq:
          json['last_seq'] as int? ?? json['lastSeq'] as int? ?? session.lastSeq,
      pendingApproval: rawApproval is Map
          ? PendingApproval.fromJson(Map<String, Object?>.from(rawApproval))
          : null,
      latestOutputSnapshot: json['latest_output_snapshot'] as String? ??
          json['latestOutputSnapshot'] as String? ??
          latestOutputSnapshot,
      hasEventGap: json['has_event_gap'] as bool? ??
          json['hasEventGap'] as bool? ??
          false,
    );
  }

  static List<BridgeEventEnvelope> _eventsFromJson(Object? rawEvents) {
    if (rawEvents is! List) return const [];
    return rawEvents.whereType<Map>().map((event) {
      return BridgeEventEnvelope.fromJson(Map<String, Object?>.from(event));
    }).toList();
  }
}

enum ChatItemRole { user, assistant, system }

class ChatItem {
  const ChatItem({
    required this.id,
    required this.role,
    required this.text,
    this.seq,
    this.snapshot = false,
    this.pending = false,
    this.failed = false,
  });

  final String id;
  final ChatItemRole role;
  final String text;
  final int? seq;
  final bool snapshot;
  final bool pending;
  final bool failed;

  ChatItem copyWith({
    bool? pending,
    bool? failed,
    int? seq,
  }) {
    return ChatItem(
      id: id,
      role: role,
      text: text,
      seq: seq ?? this.seq,
      snapshot: snapshot,
      pending: pending ?? this.pending,
      failed: failed ?? this.failed,
    );
  }

  factory ChatItem.fromJson(Map<String, Object?> json) {
    final roleName = json['role'] as String? ?? 'assistant';
    return ChatItem(
      id: json['id'] as String? ?? json['message_id'] as String? ?? '',
      role: ChatItemRole.values.firstWhere(
        (role) => role.name == roleName,
        orElse: () => ChatItemRole.assistant,
      ),
      text: json['text'] as String? ?? json['content'] as String? ?? '',
      seq: json['seq'] as int?,
      snapshot: json['snapshot'] as bool? ?? false,
    );
  }

  factory ChatItem.fromUserEvent(
    BridgeEventEnvelope envelope,
    Map<String, Object?> payload,
  ) {
    return ChatItem(
      id: payload['client_msg_id'] as String? ??
          payload['clientMsgId'] as String? ??
          'evt_${envelope.seq}',
      role: ChatItemRole.user,
      text: payload['text'] as String? ?? '',
      seq: envelope.seq,
    );
  }

  factory ChatItem.fromAssistantEvent(
    BridgeEventEnvelope envelope,
    Map<String, Object?> payload,
  ) {
    return ChatItem(
      id: payload['message_id'] as String? ??
          payload['messageId'] as String? ??
          'evt_${envelope.seq}',
      role: ChatItemRole.assistant,
      text: payload['text'] as String? ?? payload['content'] as String? ?? '',
      seq: envelope.seq,
      snapshot: payload['snapshot'] as bool? ?? false,
    );
  }

  static ChatItem? fromEvent(BridgeEventEnvelope envelope) {
    final payload = envelope.event.payload;
    switch (envelope.event.kind) {
      case 'user_message':
        final item = ChatItem.fromUserEvent(envelope, payload);
        return item.text.isEmpty ? null : item;
      case 'assistant_message':
        final item = ChatItem.fromAssistantEvent(envelope, payload);
        return item.text.isEmpty ? null : item;
      default:
        return null;
    }
  }
}

class PendingApproval {
  const PendingApproval({
    required this.approvalId,
    required this.sessionId,
    required this.operationKind,
    required this.description,
    required this.paths,
    required this.actions,
    required this.expiresAt,
    this.diffSummary,
    this.contentHash,
    this.status = 'pending',
  });

  final String approvalId;
  final String sessionId;
  final String operationKind;
  final String description;
  final List<String> paths;
  final List<String> actions;
  final DateTime expiresAt;
  final String? diffSummary;
  final String? contentHash;
  final String status;

  factory PendingApproval.fromJson(Map<String, Object?> json) {
    return PendingApproval(
      approvalId: json['approval_id'] as String? ??
          json['approvalId'] as String? ??
          '',
      sessionId: json['session_id'] as String? ??
          json['sessionId'] as String? ??
          '',
      operationKind: json['operation_kind'] as String? ??
          json['operationKind'] as String? ??
          'unknown',
      description: json['description'] as String? ?? '',
      paths: (json['paths'] as List?)?.whereType<String>().toList() ??
          const <String>[],
      actions: (json['actions'] as List?)?.whereType<String>().toList() ??
          const <String>[],
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      diffSummary: json['diff_summary'] as String? ??
          json['diffSummary'] as String?,
      contentHash: json['content_hash'] as String? ??
          json['contentHash'] as String?,
      status: json['status'] as String? ?? 'pending',
    );
  }
}
