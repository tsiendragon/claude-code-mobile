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

enum SessionBackend {
  claude,
  codex,
  opencode,
  cursor,
  unknown,
}

SessionState sessionStateFromWire(String? value) {
  return SessionState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => SessionState.unknown,
  );
}

SessionBackend sessionBackendFromWire(String? value) {
  return SessionBackend.values.firstWhere(
    (backend) => backend.name == value,
    orElse: () => SessionBackend.claude,
  );
}

String sessionBackendToWire(SessionBackend backend) {
  return switch (backend) {
    SessionBackend.codex => 'codex',
    SessionBackend.opencode => 'opencode',
    SessionBackend.cursor => 'cursor',
    SessionBackend.claude || SessionBackend.unknown => 'claude',
  };
}

String sessionBackendLabel(SessionBackend backend) {
  return switch (backend) {
    SessionBackend.claude => 'Claude Code',
    SessionBackend.codex => 'Codex',
    SessionBackend.opencode => 'Opencode',
    SessionBackend.cursor => 'Cursor',
    SessionBackend.unknown => 'Claude Code',
  };
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
  final SessionBackend backend;
  final SessionState state;
  final int lastSeq;
  final String? cwd;
  final String? lastMessage;
  final bool needsAttention;

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    return SessionSummary(
      sessionId:
          json['session_id'] as String? ?? json['sessionId'] as String? ?? '',
      name: json['name'] as String? ?? 'Session',
      backend: sessionBackendFromWire(json['backend'] as String?),
      state: sessionStateFromWire(json['state'] as String?),
      lastSeq: json['last_seq'] as int? ?? json['lastSeq'] as int? ?? 0,
      cwd: json['cwd'] as String?,
      lastMessage:
          json['last_message'] as String? ?? json['lastMessage'] as String?,
      needsAttention: json['needs_attention'] as bool? ??
          json['needsAttention'] as bool? ??
          false,
    );
  }
}

class WorkspaceSummary {
  const WorkspaceSummary({
    required this.id,
    required this.name,
    required this.path,
  });

  final String id;
  final String name;
  final String path;

  factory WorkspaceSummary.fromJson(Map<String, Object?> json) {
    final id = json['id'] as String? ??
        json['workspace_id'] as String? ??
        json['workspaceId'] as String? ??
        '';
    return WorkspaceSummary(
      id: id,
      name: json['name'] as String? ?? id,
      path: json['path'] as String? ?? '',
    );
  }
}

class SystemStats {
  const SystemStats({
    required this.memory,
    required this.loadAverage,
    required this.uptimeSeconds,
    required this.platform,
    required this.arch,
    required this.hostname,
    required this.cpuCount,
    this.cpuPercent,
  });

  final double? cpuPercent;
  final MemoryStats memory;
  final List<double> loadAverage;
  final int uptimeSeconds;
  final String platform;
  final String arch;
  final String hostname;
  final int cpuCount;

  factory SystemStats.fromJson(Map<String, Object?> json) {
    final rawMemory = json['memory'];
    return SystemStats(
      cpuPercent: (json['cpu_percent'] as num?)?.toDouble() ??
          (json['cpuPercent'] as num?)?.toDouble(),
      memory: MemoryStats.fromJson(
        rawMemory is Map
            ? Map<String, Object?>.from(rawMemory)
            : const <String, Object?>{},
      ),
      loadAverage:
          (json['load_average'] as List?)?.whereType<num>().map((value) {
                return value.toDouble();
              }).toList() ??
              const <double>[],
      uptimeSeconds:
          json['uptime_seconds'] as int? ?? json['uptimeSeconds'] as int? ?? 0,
      platform: json['platform'] as String? ?? '',
      arch: json['arch'] as String? ?? '',
      hostname: json['hostname'] as String? ?? '',
      cpuCount: json['cpu_count'] as int? ?? json['cpuCount'] as int? ?? 0,
    );
  }
}

class MemoryStats {
  const MemoryStats({
    required this.totalBytes,
    required this.freeBytes,
    required this.usedBytes,
    this.usedPercent,
  });

  final int totalBytes;
  final int freeBytes;
  final int usedBytes;
  final double? usedPercent;

  factory MemoryStats.fromJson(Map<String, Object?> json) {
    return MemoryStats(
      totalBytes:
          json['total_bytes'] as int? ?? json['totalBytes'] as int? ?? 0,
      freeBytes: json['free_bytes'] as int? ?? json['freeBytes'] as int? ?? 0,
      usedBytes: json['used_bytes'] as int? ?? json['usedBytes'] as int? ?? 0,
      usedPercent: (json['used_percent'] as num?)?.toDouble() ??
          (json['usedPercent'] as num?)?.toDouble(),
    );
  }
}

class FilePreview {
  const FilePreview({
    required this.path,
    required this.relativePath,
    required this.name,
    required this.content,
    required this.bytes,
    required this.truncated,
    required this.language,
  });

  final String path;
  final String relativePath;
  final String name;
  final String content;
  final int bytes;
  final bool truncated;
  final String language;

  bool get isMarkdown =>
      language == 'markdown' ||
      name.toLowerCase().endsWith('.md') ||
      name.toLowerCase().endsWith('.markdown');

  factory FilePreview.fromJson(Map<String, Object?> json) {
    return FilePreview(
      path: json['path'] as String? ?? '',
      relativePath: json['relative_path'] as String? ??
          json['relativePath'] as String? ??
          json['path'] as String? ??
          '',
      name: json['name'] as String? ?? 'file',
      content: json['content'] as String? ?? '',
      bytes: json['bytes'] as int? ?? 0,
      truncated: json['truncated'] as bool? ?? false,
      language: json['language'] as String? ?? 'text',
    );
  }
}

class FileReference {
  const FileReference({
    required this.path,
    required this.name,
    required this.language,
    this.relativePath,
    this.bytes,
  });

  final String path;
  final String name;
  final String language;
  final String? relativePath;
  final int? bytes;

  bool get isMarkdown =>
      language == 'markdown' ||
      name.toLowerCase().endsWith('.md') ||
      name.toLowerCase().endsWith('.markdown');

  factory FileReference.fromJson(Map<String, Object?> json) {
    final path = json['path'] as String? ?? '';
    final name = json['name'] as String? ?? _fileName(path);
    final language = json['language'] as String? ?? _languageForPath(name);
    return FileReference(
      path: path,
      name: name,
      language: language,
      relativePath:
          json['relative_path'] as String? ?? json['relativePath'] as String?,
      bytes: json['bytes'] as int?,
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
    for (final event in _eventsFromJson(rawEvents)) {
      final item = ChatItem.fromEvent(event);
      if (item == null) continue;
      eventItems.add(item);
    }

    final parsedItems = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((item) => ChatItem.fromJson(Map<String, Object?>.from(item)))
            .where((item) => item.text.isNotEmpty)
            .toList()
        : eventItems;
    final legacySnapshot = json['latest_output_snapshot'] as String? ??
        json['latestOutputSnapshot'] as String?;
    final items = [
      ...parsedItems,
      if (parsedItems.isEmpty &&
          legacySnapshot != null &&
          legacySnapshot.trim().isNotEmpty)
        ChatItem(
          id: 'latest_output_snapshot',
          role: ChatItemRole.assistant,
          text: formatAssistantText(legacySnapshot),
          snapshot: true,
        ),
    ];

    return ChatStateSnapshot(
      session: session,
      items: items,
      lastSeq: json['last_seq'] as int? ??
          json['lastSeq'] as int? ??
          session.lastSeq,
      pendingApproval: rawApproval is Map
          ? PendingApproval.fromJson(Map<String, Object?>.from(rawApproval))
          : null,
      latestOutputSnapshot: null,
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
    final role = ChatItemRole.values.firstWhere(
      (role) => role.name == roleName,
      orElse: () => ChatItemRole.assistant,
    );
    final rawText = json['text'] as String? ?? json['content'] as String? ?? '';
    return ChatItem(
      id: json['id'] as String? ?? json['message_id'] as String? ?? '',
      role: role,
      text: role == ChatItemRole.assistant
          ? formatAssistantText(rawText)
          : rawText,
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
      text: formatAssistantText(
        payload['text'] as String? ?? payload['content'] as String? ?? '',
      ),
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

String formatAssistantText(String input) {
  final cleaned = <String>[];
  for (final rawLine in input.replaceAll('\r', '').split('\n')) {
    final line = _cleanTerminalLine(rawLine);
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('✻')) continue;
    if (trimmed.startsWith('●')) {
      cleaned.add(_stripAssistantMarker(trimmed));
    } else {
      cleaned.add(line.replaceFirst(RegExp(r'^\s{0,2}'), '').trimRight());
    }
  }

  while (cleaned.isNotEmpty && cleaned.first.trim().isEmpty) {
    cleaned.removeAt(0);
  }
  while (cleaned.isNotEmpty && cleaned.last.trim().isEmpty) {
    cleaned.removeLast();
  }

  return cleaned.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

String _cleanTerminalLine(String input) {
  return input
      .replaceAll(RegExp(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])'), '')
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp('[↓↑]'), ' ')
      .trimRight();
}

String _stripAssistantMarker(String input) {
  return input
      .replaceFirst(RegExp(r'^●\s*'), '')
      .replaceFirst(RegExp(r'^[\u0300-\u036f\u0591-\u05c7\s]+'), '')
      .trimRight();
}

List<FileReference> extractFileReferences(String text) {
  final references = <FileReference>[];
  final seen = <String>{};

  for (final match in extractFileReferenceMatches(text)) {
    final path = match.path;
    if (!seen.add(path)) continue;
    references.add(FileReference(
      path: path,
      name: _fileName(path),
      language: _languageForPath(path),
    ));
  }

  return references;
}

class FileReferenceMatch {
  const FileReferenceMatch({
    required this.rawText,
    required this.path,
    required this.start,
    required this.end,
  });

  final String rawText;
  final String path;
  final int start;
  final int end;
}

List<FileReferenceMatch> extractFileReferenceMatches(String text) {
  final matches = <FileReferenceMatch>[];
  final urlSpans = _urlPattern.allMatches(text).toList();

  for (final match in _filePathPattern.allMatches(text)) {
    if (_isUrlPathMatch(text, match.start) ||
        _isInsideUrl(urlSpans, match.start, match.end)) {
      continue;
    }
    final rawPath = match.group(1);
    if (rawPath == null) continue;
    final path = _cleanFilePath(rawPath);
    if (!_isPreviewablePath(path)) continue;
    matches.add(FileReferenceMatch(
      rawText: rawPath,
      path: path,
      start: match.start,
      end: match.end,
    ));
  }

  return matches;
}

final RegExp _urlPattern = RegExp(
  r'https?://[^\s<>\]]+',
  caseSensitive: false,
);

bool _isInsideUrl(List<RegExpMatch> urlSpans, int start, int end) {
  for (final span in urlSpans) {
    if (start >= span.start && end <= span.end) return true;
  }
  return false;
}

bool _isUrlPathMatch(String text, int matchStart) {
  final windowStart = matchStart - 8 < 0 ? 0 : matchStart - 8;
  final prefix = text.substring(windowStart, matchStart);
  return prefix.contains('://') ||
      prefix.endsWith('http:') ||
      prefix.endsWith('https:');
}

final RegExp _filePathPattern = RegExp(
  r"""((?:~|/|\.{1,2}/)?[^\s`"'(<>\[\]{}，。；;:,：]+?\.(?:markdown|bash|cjs|cpp|css|csv|dart|env|go|gradle|hpp|html|ini|java|json|jsx|lock|lua|mjs|php|py|rb|rs|scss|sh|sql|swift|toml|tsx|txt|xml|yaml|yml|zsh|cc|cs|js|kt|md|ts|c|h|m|r))""",
  caseSensitive: false,
);

String _cleanFilePath(String input) {
  return input
      .trim()
      .replaceAll(RegExp("^[`\"'(<\\[]+"), '')
      .replaceAll(RegExp("[`\"')>\\],，。；;:]+\$"), '');
}

bool _isPreviewablePath(String path) {
  if (path.isEmpty) return false;
  if (path.startsWith('http://') || path.startsWith('https://')) return false;
  if (path.contains('..')) return false;
  return _languageForPath(path) != 'unknown';
}

String _fileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index >= 0 ? normalized.substring(index + 1) : normalized;
}

String _languageForPath(String path) {
  final name = _fileName(path).toLowerCase();
  if (name == 'dockerfile') return 'dockerfile';
  if (name == 'makefile') return 'makefile';
  final dot = name.lastIndexOf('.');
  final ext = dot >= 0 ? name.substring(dot + 1) : '';
  const languages = <String, String>{
    'bash': 'shell',
    'c': 'c',
    'cc': 'cpp',
    'cjs': 'javascript',
    'cpp': 'cpp',
    'cs': 'csharp',
    'css': 'css',
    'csv': 'csv',
    'dart': 'dart',
    'env': 'dotenv',
    'go': 'go',
    'gradle': 'gradle',
    'h': 'c',
    'hpp': 'cpp',
    'html': 'html',
    'ini': 'ini',
    'java': 'java',
    'js': 'javascript',
    'json': 'json',
    'jsx': 'jsx',
    'kt': 'kotlin',
    'lock': 'text',
    'lua': 'lua',
    'm': 'objective-c',
    'markdown': 'markdown',
    'md': 'markdown',
    'mjs': 'javascript',
    'php': 'php',
    'py': 'python',
    'r': 'r',
    'rb': 'ruby',
    'rs': 'rust',
    'scss': 'scss',
    'sh': 'shell',
    'sql': 'sql',
    'swift': 'swift',
    'toml': 'toml',
    'ts': 'typescript',
    'tsx': 'tsx',
    'txt': 'text',
    'xml': 'xml',
    'yaml': 'yaml',
    'yml': 'yaml',
    'zsh': 'shell',
  };
  return languages[ext] ?? 'unknown';
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
      approvalId:
          json['approval_id'] as String? ?? json['approvalId'] as String? ?? '',
      sessionId:
          json['session_id'] as String? ?? json['sessionId'] as String? ?? '',
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
      diffSummary:
          json['diff_summary'] as String? ?? json['diffSummary'] as String?,
      contentHash:
          json['content_hash'] as String? ?? json['contentHash'] as String?,
      status: json['status'] as String? ?? 'pending',
    );
  }
}
