// Runs `AgentScreen` against a stubbed herdr backend so it can be
// screenshotted/inspected on a simulator without a live SSH host.
//
// Run it with:
//
//   just preview
//
// Switch scenarios via `--dart-define`, e.g.:
//
//   just preview --dart-define=SCENARIO=blocked
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import '../l10n/app_localizations.dart';
import '../src/app_theme.dart';
import '../src/dev/stub_herdr.dart';
import '../src/herdr/herdr_client.dart';
import '../src/screens/agent_screen.dart';

void main() {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  const scenario = String.fromEnvironment('SCENARIO', defaultValue: 'idle');
  final responder = scenario == 'blocked'
      ? blockedPromptResponse
      : idleWithModeResponse;

  runApp(
    MaterialApp(
      title: 'Drover preview',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverTheme,
      home: AgentScreen(
        client: HerdrClient(StubCommandRunner(responder)),
        paneId: 'wB:p1',
        pollInterval: const Duration(hours: 1),
      ),
    ),
  );
}
