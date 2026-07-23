import 'package:drover/src/notifications/host_pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a pairing code response', () {
    final pairing = PairingCode.fromResponse({
      'pairingCode': 'code',
      'hostId': 'host-123',
      'completionUrl': 'https://example.com/completePairing',
    });

    expect(pairing.code, 'code');
    expect(pairing.hostId, 'host-123');
    expect(pairing.completionUrl, 'https://example.com/completePairing');
  });

  test('rejects a malformed pairing code response', () {
    expect(
      () => PairingCode.fromResponse({'pairingCode': 'code'}),
      throwsFormatException,
    );
  });
}
