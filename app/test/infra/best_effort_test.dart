import 'package:drover/src/infra/best_effort.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs the action', () async {
    var ran = false;
    await runBestEffort(() async {
      ran = true;
    });
    expect(ran, isTrue);
  });

  test('swallows errors thrown by the action', () async {
    await expectLater(
      runBestEffort(() async {
        throw StateError('boom');
      }),
      completes,
    );
  });

  test('swallows synchronous errors thrown before the first await', () async {
    await expectLater(
      runBestEffort(() {
        throw StateError('boom');
      }),
      completes,
    );
  });
}
