import 'package:flutter/foundation.dart';

/// Runs [action], swallowing any error so a failing best-effort side task
/// (typically a Firebase or network call) never aborts app startup or blocks a
/// local state change. Errors are surfaced via [debugPrint] in debug builds so
/// they remain observable during development.
Future<void> runBestEffort(
  Future<void> Function() action, {
  String? context,
}) async {
  try {
    await action();
  } catch (error, stackTrace) {
    if (kDebugMode) {
      debugPrint('Best-effort${context == null ? '' : ' ($context)'} '
          'failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}
