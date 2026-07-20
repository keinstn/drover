import 'package:drover/src/utils/mutex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Mutex', () {
    test(
      'serializes concurrent sections so at most one runs at a time',
      () async {
        final mutex = Mutex();
        var active = 0;
        var maxActive = 0;

        Future<void> section() {
          return mutex.run(() async {
            active++;
            maxActive = active > maxActive ? active : maxActive;
            await Future.delayed(Duration.zero);
            active--;
          });
        }

        await Future.wait([section(), section(), section(), section()]);

        expect(maxActive, 1);
      },
    );

    test('runs sections in FIFO submission order', () async {
      final mutex = Mutex();
      final order = <int>[];

      Future<void> section(int index) {
        return mutex.run(() async {
          await Future.delayed(Duration.zero);
          order.add(index);
        });
      }

      await Future.wait([section(0), section(1), section(2), section(3)]);

      expect(order, [0, 1, 2, 3]);
    });

    test(
      'a throwing section propagates to its own caller without poisoning the lock',
      () async {
        final mutex = Mutex();

        final failing = mutex.run(() async {
          await Future.delayed(Duration.zero);
          throw Exception('boom');
        });

        await expectLater(failing, throwsA(isA<Exception>()));

        final result = await mutex.run(() async => 42);
        expect(result, 42);
      },
    );
  });
}
