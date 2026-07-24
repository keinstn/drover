import 'dart:async';

import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/infra/host_connections.dart';
import 'package:drover/src/infra/ssh_command_runner.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:flutter_test/flutter_test.dart';

HostConfig _config({
  String? hostId,
  String? name,
  String privateKeyPem = 'pem',
}) => HostConfig(
  name: name,
  host: 'example.com',
  user: 'alice',
  privateKeyPem: privateKeyPem,
  hostId: hostId,
);

/// [SshCommandRunner] that never connects; records dispose calls and can
/// hold the dispose future open via [disposeGate] to test evict ordering.
class _FakeRunner extends SshCommandRunner {
  _FakeRunner(super.config);

  int disposeCalls = 0;
  Completer<void>? disposeGate;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final gate = disposeGate;
    if (gate != null) await gate.future;
  }
}

void main() {
  group('HostConnectionRegistry', () {
    late List<_FakeRunner> builtRunners;
    late HostConnectionRegistry registry;

    setUp(() {
      builtRunners = [];
      registry = HostConnectionRegistry((config) {
        final runner = _FakeRunner(config);
        builtRunners.add(runner);
        return HostConnection(
          config: config,
          runner: runner,
          client: HerdrClient(runner),
        );
      });
    });

    test('obtain builds once per hostId and caches the instance', () {
      final host = _config(hostId: 'h1');
      final first = registry.obtain(host);
      final second = registry.obtain(host);
      expect(identical(first, second), isTrue);
      expect(builtRunners, hasLength(1));
    });

    test('obtain throws ArgumentError for a null hostId', () {
      expect(() => registry.obtain(_config()), throwsArgumentError);
      expect(builtRunners, isEmpty);
    });

    test('get returns null for unknown and the cached instance for known', () {
      expect(registry.get('h1'), isNull);
      final connection = registry.obtain(_config(hostId: 'h1'));
      expect(registry.get('h1'), same(connection));
    });

    test('evict disposes the runner and the next obtain rebuilds', () async {
      final host = _config(hostId: 'h1');
      final first = registry.obtain(host);
      await registry.evict('h1');
      expect(builtRunners.single.disposeCalls, 1);
      expect(registry.get('h1'), isNull);
      final second = registry.obtain(host);
      expect(identical(first, second), isFalse);
      expect(builtRunners, hasLength(2));
    });

    test('evict of an unknown hostId completes without error', () async {
      await registry.evict('missing');
    });

    test('disposeAll disposes every runner and empties the registry', () async {
      registry.obtain(_config(hostId: 'h1'));
      registry.obtain(_config(hostId: 'h2'));
      await registry.disposeAll();
      expect(builtRunners, hasLength(2));
      for (final runner in builtRunners) {
        expect(runner.disposeCalls, 1);
      }
      expect(registry.get('h1'), isNull);
      expect(registry.get('h2'), isNull);
    });

    test('obtain with a changed connection config disposes and rebuilds', () {
      final first = registry.obtain(_config(hostId: 'h1'));
      final second = registry.obtain(
        _config(hostId: 'h1', privateKeyPem: 'new-pem'),
      );
      expect(identical(first, second), isFalse);
      expect(builtRunners, hasLength(2));
      expect(builtRunners.first.disposeCalls, 1);
      expect(second.config.privateKeyPem, 'new-pem');
      expect(registry.get('h1'), same(second));
    });

    test('obtain with only a changed name keeps the cached instance', () {
      final first = registry.obtain(_config(hostId: 'h1'));
      final second = registry.obtain(_config(hostId: 'h1', name: 'renamed'));
      expect(identical(first, second), isTrue);
      expect(builtRunners, hasLength(1));
      expect(builtRunners.single.disposeCalls, 0);
    });

    test('obtain during an in-flight evict returns a new connection', () async {
      final host = _config(hostId: 'h1');
      final first = registry.obtain(host);
      final gate = builtRunners.single.disposeGate = Completer<void>();
      final evicting = registry.evict('h1');
      // Dispose has not completed, but the entry is already gone.
      final second = registry.obtain(host);
      expect(identical(first, second), isFalse);
      expect(builtRunners, hasLength(2));
      gate.complete();
      await evicting;
      // The fresh connection survives the old one's dispose.
      expect(registry.get('h1'), same(second));
      expect(builtRunners[1].disposeCalls, 0);
    });
  });
}
