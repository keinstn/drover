import 'package:drover/src/herdr/herdr_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHerdrVersion', () {
    test('parses "herdr X.Y.Z" output', () {
      expect(parseHerdrVersion('herdr 0.7.5\n'), (0, 7, 5));
    });

    test('parses a bare version string', () {
      expect(parseHerdrVersion('0.7.5'), (0, 7, 5));
    });

    test('tolerates surrounding whitespace', () {
      expect(parseHerdrVersion('  herdr 1.2.3  \n'), (1, 2, 3));
    });

    test('returns null for output with no version', () {
      expect(parseHerdrVersion('command not found'), isNull);
    });

    test('returns null for empty output', () {
      expect(parseHerdrVersion(''), isNull);
    });
  });

  group('isHerdrVersionSupported', () {
    test('rejects a version below the minimum', () {
      expect(isHerdrVersionSupported((0, 7, 4)), isFalse);
      expect(isHerdrVersionSupported((0, 6, 9)), isFalse);
      expect(isHerdrVersionSupported((0, 0, 0)), isFalse);
    });

    test('accepts exactly the minimum version', () {
      expect(isHerdrVersionSupported(kMinHerdrVersion), isTrue);
    });

    test('accepts a version above the minimum', () {
      expect(isHerdrVersionSupported((0, 8, 1)), isTrue);
      expect(isHerdrVersionSupported((0, 9, 0)), isTrue);
      expect(isHerdrVersionSupported((1, 0, 0)), isTrue);
    });
  });

  group('formatHerdrVersion', () {
    test('joins the tuple with dots', () {
      expect(formatHerdrVersion((0, 7, 5)), '0.7.5');
    });
  });
}
