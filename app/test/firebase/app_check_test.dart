import 'package:drover/src/firebase/app_check.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the debug provider for iOS debug builds', () {
    expect(
      appleAppCheckProvider(platform: TargetPlatform.iOS, isDebug: true),
      isA<AppleDebugProvider>(),
    );
  });

  test('uses App Attest for iOS release builds', () {
    expect(
      appleAppCheckProvider(platform: TargetPlatform.iOS, isDebug: false),
      isA<AppleAppAttestProvider>(),
    );
  });

  test('does not activate App Check for unregistered macOS', () {
    expect(
      appleAppCheckProvider(platform: TargetPlatform.macOS, isDebug: false),
      isNull,
    );
  });
}
