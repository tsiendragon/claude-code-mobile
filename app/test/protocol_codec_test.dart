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

    expect(snapshot.items, hasLength(1));
    expect(snapshot.items.first.text, 'hello');
    expect(snapshot.latestOutputSnapshot, 'world');
  });
}
