// End-to-end widget coverage for drover's demo mode: the scripted session must
// actually *render* — its chat transcript, its status pills, its Markdown and
// code and diff — not just hold the data in the backend. The demo's whole
// point is teaching "read the agent's transcript as chat", so a demo showing
// only the live terminal panel is a product-level defect, and
// `demo_backend_test.dart` asserts backend state and cannot catch it. Every
// assertion in this file is therefore on what is on screen.
import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/demo/demo_content.dart';
import 'package:drover/src/demo/demo_content_en.dart';
import 'package:drover/src/demo/demo_content_ja.dart';
import 'package:drover/src/demo/demo_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text that exists ONLY in the demo's native transcript — deliberately not
/// the tool command, which also appears in the live terminal's permission
/// prompt and would therefore pass even with no transcript rendered at all.
const _thinking = "I'll create an empty file with touch.";
const _reply1 = "Done — I've created spike-test.txt";

/// A phrase unique to the *second* canned reply, which only lands after a
/// follow-up has been sent through the composer.
const _reply2 = "This demo's script ends here";

/// A line that appears only inside the fenced Dart block, and one that appears
/// only inside the fenced diff (it is a removed line, so the code block's
/// fixed version never contains it). Single lines on purpose: fenced blocks
/// are syntax-highlighted per line, so a multi-line needle would never match.
const _codeOnlyLine = "throw StateError('unreachable');";
const _diffOnlyLine = 'if (i >= attempts - 1) rethrow;';

Widget _demo(
  DemoBackend backend, {
  Locale? locale,
  VoidCallback? onOpenSettings,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: locale,
  theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
  home: DemoScreen(
    backend: backend,
    hasConfiguredHost: false,
    onExitDemo: () {},
    onOpenSettings: onOpenSettings ?? () {},
  ),
);

/// A viewport tall enough that the transcript's slivers are all built, so
/// `find` sees content the user would reach by scrolling. The agent view opens
/// scrolled to the live terminal (correct for real hosts, and out of scope
/// here), which would otherwise leave the earlier turns unbuilt.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Advances the fake clock past several `AgentScreen` poll intervals, letting
/// the (unawaited) native-history load settle. `pumpAndSettle` can't be used:
/// the screen polls on a `Timer.periodic`, which never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 2));
  }
}

Future<void> _openAgent(WidgetTester tester, String paneId) async {
  await tester.tap(find.byKey(ValueKey('agent-$demoHostId-$paneId')));
  await _settle(tester);
}

Future<void> _openScriptedAgent(WidgetTester tester) =>
    _openAgent(tester, demoPaneId);

/// The composer, found by its own key rather than by `TextField`: a key says
/// "this control" unambiguously in both the present and the absent assertion,
/// and survives the composer's internal layout changing.
final _composer = find.byKey(const ValueKey('agent_composer'));

void main() {
  testWidgets('the demo session renders its chat transcript', (tester) async {
    _useTallViewport(tester);

    await tester.pumpWidget(_demo(DemoBackend()));
    await _settle(tester);
    await _openScriptedAgent(tester);

    // Blocked state: the scripted transcript is already non-empty, so chat
    // content must be on screen alongside the permission prompt.
    expect(find.text('Conversation history'), findsOneWidget);
    expect(
      find.textContaining(demoContentEn.userSetup, findRichText: true),
      findsOneWidget,
    );
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

  testWidgets(
    'the scripted session renders Markdown, a fenced code block and a diff',
    (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(_demo(DemoBackend()));
      await _settle(tester);
      await _openScriptedAgent(tester);

      // Markdown: the heading and a bullet from the assistant's overview.
      expect(
        find.textContaining('Retry helper', findRichText: true),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining(
          'how many tries it gets before giving up',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // The fenced Dart block and the fenced diff, each via a line unique to
      // it.
      expect(
        find.textContaining(_codeOnlyLine, findRichText: true),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining(_diffOnlyLine, findRichText: true),
        findsAtLeastNWidgets(1),
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the herd screen shows three agents with meaningful status pills',
    (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(_demo(DemoBackend()));
      await _settle(tester);

      // One tile per agent, and each agent's session title on screen.
      expect(
        find.byKey(ValueKey('agent-$demoHostId-$demoPaneId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('agent-$demoHostId-$demoReviewPaneId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('agent-$demoHostId-$demoDocsPaneId')),
        findsOneWidget,
      );
      expect(find.text(demoContentEn.scriptedTitle), findsOneWidget);
      expect(find.text(demoContentEn.reviewTitle), findsOneWidget);
      expect(find.text(demoContentEn.docsTitle), findsOneWidget);

      // The status row teaches the vocabulary only if it carries real counts
      // (these are the en labels from app_en.arb, verbatim).
      expect(find.text('waiting for you 1'), findsOneWidget);
      expect(find.text('working 1'), findsOneWidget);
      expect(find.text('resting 1'), findsOneWidget);
      expect(find.text('all done 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the scenery agents have no composer', (tester) async {
    _useTallViewport(tester);

    await tester.pumpWidget(_demo(DemoBackend()));
    await _settle(tester);

    // Hidden, not wired to a canned reply: nothing is behind these panes, and
    // a send that silently swallows a typed message is worse than no control
    // at all — the user pays the typing first.
    await _openAgent(tester, demoReviewPaneId);
    expect(_composer, findsNothing);

    // Back to the herd via the switcher bar's herd tab, then the other one.
    await tester.tap(find.byKey(const ValueKey('switcher_herd_tab')));
    await _settle(tester);
    await _openAgent(tester, demoDocsPaneId);
    expect(_composer, findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'switching to a scenery agent from the switcher bar drops the composer',
    (tester) async {
      _useTallViewport(tester);

      await tester.pumpWidget(_demo(DemoBackend()));
      await _settle(tester);
      await _openScriptedAgent(tester);
      expect(_composer, findsOneWidget);

      // The bottom bar replaces this screen in place rather than going back
      // through the herd, so the composer decision has to be re-asked for the
      // pane switched *to* — the path a per-screen flag would get wrong.
      await tester.tap(
        find.byKey(ValueKey('switcher_agent_$demoReviewPaneId')),
      );
      await _settle(tester);
      expect(_composer, findsNothing);

      // And switching back restores it.
      await tester.tap(find.byKey(ValueKey('switcher_agent_$demoPaneId')));
      await _settle(tester);
      expect(_composer, findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the scripted agent keeps a working composer', (tester) async {
    _useTallViewport(tester);

    await tester.pumpWidget(_demo(DemoBackend()));
    await _settle(tester);
    await _openScriptedAgent(tester);

    expect(_composer, findsOneWidget);

    // Answer the permission prompt so the session reaches the phase that
    // accepts a follow-up.
    await tester.tap(find.widgetWithText(FilledButton, 'Yes'));
    await _settle(tester);

    // Send a follow-up through the real composer, and require the canned
    // second reply to *render* — hiding the scenery composers must not break
    // the one interactive path the demo exists to show.
    await tester.enterText(
      find.descendant(of: _composer, matching: find.byType(TextField)),
      'and now run the tests',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send_message_button')));
    await _settle(tester);

    expect(find.textContaining(_reply2, findRichText: true), findsOneWidget);
    // The user's own follow-up is echoed back into the transcript too.
    expect(
      find.textContaining('and now run the tests', findRichText: true),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the demo has no host switcher control', (tester) async {
    _useTallViewport(tester);

    await tester.pumpWidget(_demo(DemoBackend()));
    await _settle(tester);

    // Hidden, not disabled or empty: the demo has no hosts to switch between.
    expect(find.byKey(const ValueKey('host_switcher_chip')), findsNothing);
    expect(find.text('All hosts'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the settings control in the demo is wired to a real callback', (
    tester,
  ) async {
    _useTallViewport(tester);
    var opened = 0;

    await tester.pumpWidget(
      _demo(DemoBackend(), onOpenSettings: () => opened++),
    );
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pump();

    // main_test.dart covers the other half — that this callback really lands
    // on the settings screen.
    expect(opened, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'in ja, what the user wrote is Japanese and what the CLI emitted stays '
    'English',
    (tester) async {
      _useTallViewport(tester);

      final backend = DemoBackend(content: demoContentFor(const Locale('ja')));
      await tester.pumpWidget(_demo(backend, locale: const Locale('ja')));
      await _settle(tester);

      // The session title on the herd screen is the user's own words.
      expect(find.text(demoContentJa.scriptedTitle), findsOneWidget);
      expect(find.text(demoContentJa.reviewTitle), findsOneWidget);

      await _openScriptedAgent(tester);

      // Localized: the user's turns and the assistant's prose.
      expect(
        find.textContaining(demoContentJa.userSetup, findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining(demoContentJa.userTour, findRichText: true),
        findsOneWidget,
      );

      // Deliberately English, and asserted so nobody "fixes" it: the
      // permission prompt body is CLI output, and drover's own parsers match
      // its literals (see claude_askuser_submitter.dart's 'Esc to cancel').
      expect(
        find.textContaining('Do you want to proceed?', findRichText: true),
        findsAtLeastNWidgets(1),
      );
      // Same for code and diff contents, which are file contents, not prose.
      expect(
        find.textContaining(_codeOnlyLine, findRichText: true),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining(_diffOnlyLine, findRichText: true),
        findsAtLeastNWidgets(1),
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
