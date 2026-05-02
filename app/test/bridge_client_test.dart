import 'package:ccm_mobile/protocol/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeClient.runSession', () {
    test('requires one session target', () async {
      final client = BridgeClient();

      await expectLater(
        client.runSession(name: 'Demo'),
        throwsA(
          isA<BridgeException>().having(
            (error) => error.message,
            'message',
            'Choose exactly one workspace or working directory.',
          ),
        ),
      );
    });

    test('rejects ambiguous session targets', () async {
      final client = BridgeClient();

      await expectLater(
        client.runSession(
          name: 'Demo',
          workspaceId: 'demo-app',
          cwd: '/tmp/demo-app',
        ),
        throwsA(
          isA<BridgeException>().having(
            (error) => error.message,
            'message',
            'Choose exactly one workspace or working directory.',
          ),
        ),
      );
    });
  });
}
