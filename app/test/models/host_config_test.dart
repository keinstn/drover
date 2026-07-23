import 'package:drover/src/models/host_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  HostConfig sample({String? hostKeyFingerprint}) => HostConfig(
    host: 'example.com',
    port: 2222,
    user: 'alice',
    privateKeyPem: '-----BEGIN KEY-----',
    passphrase: 'secret',
    herdrBin: '/usr/bin/herdr',
    hostId: 'host-1',
    hostKeyFingerprint: hostKeyFingerprint,
  );

  group('toJson/fromJson', () {
    test('round-trips hostKeyFingerprint when set', () {
      final config = sample(hostKeyFingerprint: 'SHA256:abc');
      final restored = HostConfig.fromJson(config.toJson());
      expect(restored.hostKeyFingerprint, 'SHA256:abc');
    });

    test('round-trips a null hostKeyFingerprint', () {
      final config = sample();
      final restored = HostConfig.fromJson(config.toJson());
      expect(restored.hostKeyFingerprint, isNull);
    });

    test('fromJson of a map missing the key yields null', () {
      final restored = HostConfig.fromJson({
        'host': 'example.com',
        'port': 22,
        'user': 'alice',
        'privateKeyPem': '-----BEGIN KEY-----',
      });
      expect(restored.hostKeyFingerprint, isNull);
    });
  });

  group('withHostKeyFingerprint', () {
    test('sets the fingerprint and preserves all other fields', () {
      final config = sample();
      final updated = config.withHostKeyFingerprint('SHA256:new');
      expect(updated.hostKeyFingerprint, 'SHA256:new');
      expect(updated.host, config.host);
      expect(updated.port, config.port);
      expect(updated.user, config.user);
      expect(updated.privateKeyPem, config.privateKeyPem);
      expect(updated.passphrase, config.passphrase);
      expect(updated.herdrBin, config.herdrBin);
      expect(updated.hostId, config.hostId);
    });
  });

  group('withHostId', () {
    test('preserves hostKeyFingerprint', () {
      final config = sample(hostKeyFingerprint: 'SHA256:abc');
      final updated = config.withHostId('host-2');
      expect(updated.hostId, 'host-2');
      expect(updated.hostKeyFingerprint, 'SHA256:abc');
    });
  });
}
