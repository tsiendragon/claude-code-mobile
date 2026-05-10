import 'package:flutter_test/flutter_test.dart';
import 'package:ccm_mobile/protocol/codec.dart';
import 'package:ccm_mobile/protocol/models.dart';

void main() {
  test('encodes bridge requests', () {
    final encoded = encodeBridgeRequest(
      type: 'session.attach',
      id: 'req_1',
      data: {'session_id': 'sess_abc'},
    );

    expect(encoded, contains('"type":"session.attach"'));
    expect(encoded, contains('"id":"req_1"'));
    expect(encoded, contains('"session_id":"sess_abc"'));
  });

  test('decodes bridge responses', () {
    final decoded = decodeBridgeMessage(
      '{"type":"response","id":"req_1","ok":true,"data":{"value":1}}',
    );

    expect(decoded, isA<BridgeResponse>());
    expect((decoded as BridgeResponse).data?['value'], 1);
  });

  test('decodes bridge events', () {
    final decoded = decodeBridgeMessage(
      '{"type":"event","session_id":"sess_abc","seq":42,'
      '"event":{"kind":"state_changed","state":"thinking"}}',
    );

    expect(decoded, isA<BridgeEventEnvelope>());
    final envelope = decoded as BridgeEventEnvelope;
    expect(envelope.sessionId, 'sess_abc');
    expect(envelope.seq, 42);
    expect(envelope.event.kind, 'state_changed');
  });

  test('parses workspace summaries', () {
    final workspace = WorkspaceSummary.fromJson({
      'id': 'demo-app',
      'name': 'Demo App',
      'path': '/home/user/workspace/demo-app',
    });

    expect(workspace.id, 'demo-app');
    expect(workspace.name, 'Demo App');
    expect(workspace.path, '/home/user/workspace/demo-app');
  });

  test('parses system stats', () {
    final stats = SystemStats.fromJson({
      'cpu_percent': 23.4,
      'memory': {
        'total_bytes': 1024,
        'free_bytes': 256,
        'used_bytes': 768,
        'used_percent': 75,
      },
      'load_average': [0.1, 0.2, 0.3],
      'uptime_seconds': 3600,
      'platform': 'linux',
      'arch': 'x64',
      'hostname': 'server',
      'cpu_count': 8,
    });

    expect(stats.cpuPercent, 23.4);
    expect(stats.memory.usedPercent, 75);
    expect(stats.loadAverage, [0.1, 0.2, 0.3]);
    expect(stats.cpuCount, 8);
  });

  test('parses resolved file references', () {
    final reference = FileReference.fromJson({
      'path': '/home/tsien/workspace/test/report.md',
      'relative_path': 'report.md',
      'name': 'report.md',
      'bytes': 12,
      'language': 'markdown',
    });

    expect(reference.isMarkdown, isTrue);
    expect(reference.relativePath, 'report.md');
    expect(reference.bytes, 12);
  });

  test('parses session backend summaries', () {
    final session = SessionSummary.fromJson({
      'session_id': 'sess_abcdefgh',
      'name': 'Demo',
      'backend': 'codex',
      'state': 'ready',
      'last_seq': 0,
    });

    expect(session.backend, SessionBackend.codex);
    expect(sessionBackendLabel(session.backend), 'Codex');
  });

  test('builds chat snapshot from attach recent events', () {
    final snapshot = ChatStateSnapshot.fromAttachResponse({
      'session': {
        'session_id': 'sess_abcdefgh',
        'name': 'Demo',
        'backend': 'claude',
        'state': 'ready',
        'last_seq': 2,
      },
      'last_seq': 2,
      'recent_events': [
        {
          'type': 'event',
          'session_id': 'sess_abcdefgh',
          'seq': 1,
          'event': {
            'kind': 'user_message',
            'clientMsgId': 'cmsg_123456',
            'text': 'hello',
          },
        },
        {
          'type': 'event',
          'session_id': 'sess_abcdefgh',
          'seq': 2,
          'event': {
            'kind': 'assistant_message',
            'text': 'world',
            'snapshot': true,
          },
        },
      ],
    });

    expect(snapshot.items, hasLength(2));
    expect(snapshot.items.first.text, 'hello');
    expect(snapshot.items.last.text, 'world');
    expect(snapshot.latestOutputSnapshot, isNull);
  });

  test('formats Claude terminal assistant output for chat bubbles', () {
    final item = ChatItem.fromAssistantEvent(
      const BridgeEventEnvelope(
        sessionId: 'sess_abcdefgh',
        seq: 2,
        event: DomainEvent(
          kind: 'assistant_message',
          payload: {
            'kind': 'assistant_message',
            'text': '● ִ I can help↓with that.\n'
                '\n'
                '  - First option\n'
                '  - Second option\n'
                '✻ Cogitated for 2s',
            'snapshot': true,
          },
        ),
      ),
      {
        'text': '● ִ I can help↓with that.\n'
            '\n'
            '  - First option\n'
            '  - Second option\n'
            '✻ Cogitated for 2s',
        'snapshot': true,
      },
    );

    expect(
        item.text, 'I can help with that.\n\n- First option\n- Second option');
  });

  test('extracts previewable file references from assistant text', () {
    final references = extractFileReferences(
      'Write(gemma4_e4b_report.md)\n'
      '报告已生成，保存至 /home/tsien/workspace/test/gemma4_e4b_report.md。\n'
      'Also wrote src/main.ts and ignored https://example.com/readme.md\n'
      '中文文件：研究报告.md',
    );

    expect(references.map((item) => item.path), [
      'gemma4_e4b_report.md',
      '/home/tsien/workspace/test/gemma4_e4b_report.md',
      'src/main.ts',
      '研究报告.md',
    ]);
    expect(references.first.isMarkdown, isTrue);
    expect(references[2].language, 'typescript');
    expect(references.last.language, 'markdown');
  });

  test('extracts file reference positions for inline links', () {
    final matches = extractFileReferenceMatches(
      'See [Report](report.md), output.md, and https://example.com/readme.md',
    );

    expect(matches.map((item) => item.path), [
      'report.md',
      'output.md',
    ]);
    expect(matches.last.rawText, 'output.md');
  });

  test('parses file previews', () {
    final preview = FilePreview.fromJson({
      'path': '/home/tsien/workspace/test/report.md',
      'relative_path': 'report.md',
      'name': 'report.md',
      'content': '# Report',
      'bytes': 8,
      'truncated': false,
      'language': 'markdown',
    });

    expect(preview.isMarkdown, isTrue);
    expect(preview.relativePath, 'report.md');
    expect(preview.content, '# Report');
  });
}
