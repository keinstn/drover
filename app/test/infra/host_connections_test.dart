import 'dart:async';

import 'package:drover/src/demo/demo_herdr.dart' show StubCommandRunner;
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/hc_client.dart';
import 'package:drover/src/herdr/herdr_backend.dart';
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
  int invalidateCalls = 0;
  bool throwOnInvalidate = false;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final gate = disposeGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> invalidateConnection() async {
    invalidateCalls++;
    if (throwOnInvalidate) throw StateError('boom');
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

    test('invalidateAll invalidates every cached runner without rebuilding or '
        'removing any entry', () async {
      final first = registry.obtain(_config(hostId: 'h1'));
      final second = registry.obtain(_config(hostId: 'h2'));

      await registry.invalidateAll();

      for (final runner in builtRunners) {
        expect(runner.invalidateCalls, 1);
        expect(runner.disposeCalls, 0);
      }
      expect(builtRunners, hasLength(2));
      expect(registry.get('h1'), same(first));
      expect(registry.get('h2'), same(second));
      // obtain() must also still return the same (not rebuilt) instance.
      expect(registry.obtain(_config(hostId: 'h1')), same(first));
      expect(registry.obtain(_config(hostId: 'h2')), same(second));
    });

    test(
      'invalidateAll on an empty registry completes without error',
      () async {
        await registry.invalidateAll();
        expect(builtRunners, isEmpty);
      },
    );

    test('invalidateAll isolates a throwing runner so later hosts are still '
        'invalidated', () async {
      registry.obtain(_config(hostId: 'h1'));
      registry.obtain(_config(hostId: 'h2'));
      builtRunners.first.throwOnInvalidate = true;

      await registry.invalidateAll();

      expect(builtRunners[0].invalidateCalls, 1);
      expect(
        builtRunners[1].invalidateCalls,
        1,
        reason: 'h1 throwing must not stop h2 from being invalidated',
      );
    });
  });

  group('buildHerdrClient', () {
    test('builds the client for the host backend', () {
      final runner = StubCommandRunner((_) => _ok(''));
      expect(buildHerdrClient(_config(), runner), isNot(isA<HcClient>()));
      final hc = HostConfig.fromJson({..._config().toJson(), 'backend': 'hc'});
      expect(buildHerdrClient(hc, runner).backend, HerdrBackend.hc);
    });
  });

  group('hostHasOnlyHc', () {
    // [path] answers the PATH probe, [local] the ~/.local/bin probe.
    Future<bool> probe({
      String path = '',
      String local = '',
      bool windows = false,
    }) => hostHasOnlyHc(
      StubCommandRunner((command) {
        if (command == 'uname -s') {
          return windows
              ? CommandResult(exitCode: 1, stdout: '', stderr: '')
              : _ok('Linux\n');
        }
        if (command == 'cmd.exe /c ver') {
          return _ok('Microsoft Windows [Version 10.0]\n');
        }
        if (command.contains('.local/bin')) return _ok(local);
        return _ok(path);
      }),
    );

    test('true only when hc is at ~/.local/bin and herdr is nowhere', () async {
      expect(await probe(local: 'hc\n'), isTrue);
    });

    test('an hc found only elsewhere on PATH does not count', () async {
      expect(await probe(path: 'hc\n'), isFalse);
    });

    test('false when herdr is found anywhere', () async {
      expect(await probe(path: 'herdr\n', local: 'hc\n'), isFalse);
      expect(await probe(local: 'herdr\nhc\n'), isFalse);
    });

    test('false when neither is found', () async {
      expect(await probe(), isFalse);
    });

    test('false on a Windows host', () async {
      expect(await probe(local: 'hc\n', windows: true), isFalse);
    });
  });

  group('isHerdrBinaryMissing', () {
    test('matches the shell reporting herdr missing', () {
      for (final message in [
        'herdr agent list failed (exit 127): ',
        'herdr agent list failed (exit 1): sh: herdr: not found',
        'herdr agent list failed (exit 2): No such file or directory',
      ]) {
        expect(
          isHerdrBinaryMissing(HerdrException('transport', message)),
          isTrue,
          reason: message,
        );
      }
    });

    test('ignores SSH failures and other errors', () {
      expect(
        isHerdrBinaryMissing(
          HerdrException('transport', 'not found', cause: StateError('ssh')),
        ),
        isFalse,
      );
      expect(
        isHerdrBinaryMissing(const HerdrException('pane_not_found', 'x')),
        isFalse,
      );
      expect(isHerdrBinaryMissing(StateError('exit 127')), isFalse);
    });
  });
}

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
