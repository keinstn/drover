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

  group('sameConnection', () {
    HostConfig variant({
      String? name,
      String? host,
      int? port,
      String? user,
      String? privateKeyPem,
      String? passphrase,
      String? herdrBin,
      String? hostId,
      String? hostKeyFingerprint,
    }) {
      final base = sample();
      return HostConfig(
        name: name,
        host: host ?? base.host,
        port: port ?? base.port,
        user: user ?? base.user,
        privateKeyPem: privateKeyPem ?? base.privateKeyPem,
        passphrase: passphrase ?? base.passphrase,
        herdrBin: herdrBin ?? base.herdrBin,
        hostId: hostId ?? base.hostId,
        hostKeyFingerprint: hostKeyFingerprint,
      );
    }

    test('ignores name, hostId, and hostKeyFingerprint', () {
      final cosmetic = variant(
        name: 'renamed',
        hostId: 'host-2',
        hostKeyFingerprint: 'SHA256:abc',
      );
      expect(sample().sameConnection(cosmetic), isTrue);
    });

    test('detects a change in each connection-relevant field', () {
      final changed = [
        variant(host: 'other.example.com'),
        variant(port: 22),
        variant(user: 'bob'),
        variant(privateKeyPem: '-----BEGIN OTHER KEY-----'),
        variant(passphrase: 'different'),
        variant(herdrBin: '/opt/herdr'),
      ];
      for (final other in changed) {
        expect(sample().sameConnection(other), isFalse);
      }
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
