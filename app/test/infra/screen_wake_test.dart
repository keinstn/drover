import 'package:drover/src/infra/screen_wake.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.keinstn.drover/screen');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('setEnabled(true) invokes setKeepAwake with enabled: true', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await PlatformScreenWake().setEnabled(true);

    expect(received?.method, 'setKeepAwake');
    expect(received?.arguments, {'enabled': true});
  });

  test('setEnabled(false) invokes setKeepAwake with enabled: false', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await PlatformScreenWake().setEnabled(false);

    expect(received?.method, 'setKeepAwake');
    expect(received?.arguments, {'enabled': false});
  });

  test(
    'with no handler installed, the call completes without throwing',
    () async {
      // The real macOS/test situation: no native handler is registered, so the
      // channel throws MissingPluginException. runBestEffort must swallow it.
      await expectLater(PlatformScreenWake().setEnabled(true), completes);
    },
  );
}
