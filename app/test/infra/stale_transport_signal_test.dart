import 'dart:async';

import 'package:drover/src/infra/network_change_signal.dart';
import 'package:drover/src/infra/stale_transport_signal.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [NetworkChangeSignal] test double whose [changes] the test drives
/// directly, with no platform channel involved.
class _FakeNetworkChangeSignal implements NetworkChangeSignal {
  final _controller = StreamController<void>.broadcast();
  bool disposed = false;

  void emit() => _controller.add(null);

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }
}

void main() {
  group('StaleTransportSignal', () {
    late _FakeNetworkChangeSignal network;
    late StaleTransportSignal signal;

    setUp(() {
      network = _FakeNetworkChangeSignal();
      signal = StaleTransportSignal(
        network,
        debounce: const Duration(milliseconds: 10),
      );
    });

    test('a network event emits once', () async {
      final events = <void>[];
      signal.changes.listen(events.add);

      network.emit();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(events, hasLength(1));
    });

    test('markStale() emits once', () async {
      final events = <void>[];
      signal.changes.listen(events.add);

      signal.markStale();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(events, hasLength(1));
    });

    test('a network event and markStale() within the debounce window coalesce '
        'into exactly one event', () async {
      final events = <void>[];
      signal.changes.listen(events.add);

      network.emit();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      signal.markStale();

      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(events, hasLength(1));
    });

    test('dispose() cancels the pending debounce timer', () async {
      final events = <void>[];
      signal.changes.listen(events.add);

      // Schedule a debounced emission, then dispose before it fires. If
      // `dispose()` didn't cancel the timer, it would fire after the
      // controller is closed and throw.
      signal.markStale();
      await signal.dispose();
      expect(network.disposed, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, isEmpty);
    });
  });
}
