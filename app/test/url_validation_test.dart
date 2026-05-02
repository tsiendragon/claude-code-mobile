import 'package:flutter_test/flutter_test.dart';
import 'package:ccm_mobile/core/config/url_validation.dart';

void main() {
  group('validateServerUrl', () {
    test('allows wss URLs', () {
      final result = validateServerUrl(
        'wss://ccm.example.com/ws',
        allowPrivateWs: false,
      );

      expect(result.isValid, isTrue);
      expect(result.risk, ServerUrlRisk.none);
    });

    test('allows localhost ws URLs', () {
      final result = validateServerUrl(
        'ws://127.0.0.1:8900',
        allowPrivateWs: false,
      );

      expect(result.isValid, isTrue);
    });

    test('requires opt-in for private ws URLs', () {
      final result = validateServerUrl(
        'ws://192.168.1.20:8900',
        allowPrivateWs: false,
      );

      expect(result.isValid, isFalse);
    });

    test('flags Tailscale range when allowed', () {
      final result = validateServerUrl(
        'ws://100.100.10.10:8900',
        allowPrivateWs: true,
      );

      expect(result.isValid, isTrue);
      expect(result.risk, ServerUrlRisk.tailscale);
    });

    test('rejects public ws URLs', () {
      final result = validateServerUrl(
        'ws://example.com/ws',
        allowPrivateWs: true,
      );

      expect(result.isValid, isFalse);
    });
  });
}
