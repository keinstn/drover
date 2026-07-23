import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Returns the configured App Check provider for supported platforms.
///
/// macOS is intentionally excluded until its Firebase app is enrolled in App
/// Check, because its provider is not configured yet.
AppleAppCheckProvider? appleAppCheckProvider({
  required TargetPlatform platform,
  required bool isDebug,
}) {
  if (platform != TargetPlatform.iOS) return null;
  return isDebug ? const AppleDebugProvider() : const AppleAppAttestProvider();
}
