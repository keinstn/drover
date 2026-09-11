import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drover/src/infra/network_change_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConnectivityChangeSignal', () {
    late StreamController<List<ConnectivityResult>> source;
    late ConnectivityChangeSignal signal;

    setUp(() {
      source = StreamController<List<ConnectivityResult>>.broadcast();
    });

    tearDown(() async {
      await signal.dispose();
      await source.close();
    });

    test('coalesces a burst of events into a single emission', () async {
      signal = ConnectivityChangeSignal(
        source: source.stream,
        debounce: const Duration(milliseconds: 10),
      );
      final events = <void>[];
      signal.changes.listen(events.add);

      source
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      source.add([ConnectivityResult.wifi]);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, hasLength(1));
    });

    test('does not emit for a transition into "no connectivity"', () async {
      signal = ConnectivityChangeSignal(
        source: source.stream,
        debounce: const Duration(milliseconds: 10),
      );
      final events = <void>[];
      signal.changes.listen(events.add);

      // Prime the baseline guard with a real-interface report first, so the
      // `none` report below is actually exercised by the `none` filter
      // rather than being swallowed as the baseline itself (which every
      // first report is, regardless of the filter — see the class doc
      // comment on [ConnectivityChangeSignal]).
      source.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, isEmpty, reason: 'the baseline report never emits');

      source.add([ConnectivityResult.none]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, isEmpty);
    });

    test(
      'emits for the transition back from none to a real interface',
      () async {
        signal = ConnectivityChangeSignal(
          source: source.stream,
          debounce: const Duration(milliseconds: 10),
        );
        final events = <void>[];
        signal.changes.listen(events.add);

        // Prime the baseline guard first (see the test above).
        source.add([ConnectivityResult.wifi]);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        source.add([ConnectivityResult.none]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        source.add([ConnectivityResult.wifi]);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(events, hasLength(1));
      },
    );

    test('changes is a broadcast stream supporting two listeners', () async {
      signal = ConnectivityChangeSignal(
        source: source.stream,
        debounce: const Duration(milliseconds: 10),
      );
      final a = <void>[];
      final b = <void>[];
      signal.changes.listen(a.add);
      signal.changes.listen(b.add);

      source.add([ConnectivityResult.wifi]); // baseline, swallowed
      source.add([ConnectivityResult.wifi]); // the actual change
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });

    test(
      'treats the first source report as a baseline: no emission even '
      'after the debounce elapses, but the following report does emit',
      () async {
        signal = ConnectivityChangeSignal(
          source: source.stream,
          debounce: const Duration(milliseconds: 10),
        );
        final events = <void>[];
        signal.changes.listen(events.add);

        source.add([ConnectivityResult.wifi]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(events, isEmpty);

        source.add([ConnectivityResult.wifi]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(events, hasLength(1));
      },
    );
  });
}
