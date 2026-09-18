import 'package:flutter/services.dart';

import 'best_effort.dart';

/// Keeps the screen from auto-locking while a Gemini Live voice session is
/// open — the user is talking, not touching the screen, and an auto-lock
/// kills the session's microphone.
abstract interface class ScreenWake {
  Future<void> setEnabled(bool enabled);
}

/// Best-effort over a platform channel: unimplemented on macOS/tests, where
/// it must silently no-op rather than throw.
class PlatformScreenWake implements ScreenWake {
  static const _channel = MethodChannel('com.keinstn.drover/screen');

  @override
  Future<void> setEnabled(bool enabled) => runBestEffort(
    () => _channel.invokeMethod<void>('setKeepAwake', {'enabled': enabled}),
  );
}
