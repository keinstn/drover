import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/widgets/agent_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AgentStatus? status, {bool disableAnimations = false}) =>
    MaterialApp(
      theme: droverDarkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Center(
            child: AgentAvatar(agent: 'claude', status: status),
          ),
        ),
      ),
    );

final _ring = find.descendant(
  of: find.byType(AgentAvatar),
  matching: find.byWidgetPredicate(
    (w) => w is CustomPaint && w.foregroundPainter != null,
  ),
);

void main() {
  testWidgets('without a status it is the bare face', (tester) async {
    await tester.pumpWidget(_app(null));

    expect(tester.getSize(find.byType(AgentAvatar)), const Size(40, 40));
    expect(_ring, findsNothing);
    expect(
      find.descendant(
        of: find.byType(AgentAvatar),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });

  testWidgets('any status reserves the same ring space', (tester) async {
    for (final status in AgentStatus.values) {
      await tester.pumpWidget(_app(status, disableAnimations: true));
      expect(
        tester.getSize(find.byType(AgentAvatar)),
        const Size.square(40 + 2 * AgentAvatar.ringInset),
        reason: '$status',
      );
    }
  });

  testWidgets('blocked draws a ring and announces the status', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(AgentStatus.blocked));

    expect(_ring, findsOneWidget);
    expect(find.bySemanticsLabel('waiting for you'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('done draws a ring', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.done));
    expect(_ring, findsOneWidget);
  });

  testWidgets('idle and unknown dim the face without a ring', (tester) async {
    for (final status in [AgentStatus.idle, AgentStatus.unknown]) {
      await tester.pumpWidget(_app(status));
      expect(_ring, findsNothing);
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.55);
    }
  });

  testWidgets('working ring animates', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.working));
    expect(_ring, findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('working ring is static under reduced motion', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.working, disableAnimations: true));
    // Settles (no repeating ticker) and still shows the ring.
    await tester.pumpAndSettle();
    expect(_ring, findsOneWidget);
  });

  testWidgets('working ring is a comet on a faint track', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.working, disableAnimations: true));
    final dot = DroverColors.of(
      tester.element(find.byType(AgentAvatar)),
    ).statusDot(AgentStatus.working);
    expect(
      tester.renderObject(_ring),
      paints
        ..rrect() // the face
        ..rrect(color: dot.withValues(alpha: 0.18), strokeWidth: 2)
        // At phase 0 the tail wraps past the path start: two segments.
        ..path(color: dot.withValues(alpha: 0.35))
        ..path(color: dot.withValues(alpha: 0.35))
        ..path(color: dot.withValues(alpha: 1)),
    );
  });
}
