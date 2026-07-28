// End-to-end widget coverage for drover's demo mode: the scripted session must
// actually *render* its chat transcript, not just hold it in the backend. The
// demo's whole point is teaching "read the agent's transcript as chat", so a
// demo showing only the live terminal panel is a product-level defect —
// `demo_backend_test.dart` asserts backend state and cannot catch it.
import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/demo/demo_screen.dart';
import 'package:drover/src/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text that exists ONLY in the demo's native transcript — deliberately not
/// the tool command, which also appears in the live terminal's permission
/// prompt and would therefore pass even with no transcript rendered at all.
const _userTurn =
    'Can you set up a quick test file so I can see how this '
    'works?';
const _thinking = "I'll create an empty file with touch.";
const _reply1 = "Done — I've created spike-test.txt";

Widget _demo(DemoBackend backend) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
  home: DemoScreen(
    backend: backend,
    hasConfiguredHost: false,
    onExitDemo: () {},
  ),
);

/// Advances the fake clock past several `AgentScreen` poll intervals, letting
/// the (unawaited) native-history load settle. `pumpAndSettle` can't be used:
/// the screen polls on a `Timer.periodic`, which never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 2));
  }
}

void main() {
  testWidgets('the demo session renders its chat transcript', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final backend = DemoBackend();
    await tester.pumpWidget(_demo(backend));
    await _settle(tester);

    // Open the single demo agent from the herd list.
    await tester.tap(find.byKey(ValueKey('agent-$demoHostId-$demoPaneId')));
    await _settle(tester);

    // Blocked state: the scripted transcript is already non-empty, so chat
    // content must be on screen alongside the permission prompt.
    expect(find.text('Conversation history'), findsOneWidget);
    expect(find.textContaining(_userTurn, findRichText: true), findsOneWidget);
    // The thinking row renders collapsed; expanding it reveals its body.
    expect(find.text('Thinking…'), findsOneWidget);
    await tester.tap(find.text('Thinking…'));
    await tester.pump();
    expect(find.textContaining(_thinking, findRichText: true), findsOneWidget);
    // The tool_use renders as a chip named after the tool.
    expect(find.text('Bash'), findsOneWidget);

    // Answering the prompt advances the script; the canned reply must land in
    // the transcript view too.
    await tester.tap(find.widgetWithText(FilledButton, 'Yes'));
    await _settle(tester);

    expect(find.textContaining(_reply1, findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
