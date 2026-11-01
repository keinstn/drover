import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/widgets/agent_status_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(
  AgentStatus status, {
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
}) => MaterialApp(
  theme: droverDarkTheme,
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(child: AgentStatusIndicator(status: status)),
    ),
  ),
);

final _spinner = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is SpinnerPainter,
);

Color _dot(WidgetTester tester, AgentStatus status) => DroverColors.of(
  tester.element(find.byType(AgentStatusIndicator)),
).statusDot(status);

BoxDecoration _circle(WidgetTester tester) =>
    tester
            .widget<Container>(
              find.descendant(
                of: find.byType(AgentStatusIndicator),
                matching: find.byType(Container),
              ),
            )
            .decoration!
        as BoxDecoration;

void main() {
  testWidgets('working spinner animates', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.working));
    expect(_spinner, findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('working spinner is a static quarter arc on a faint track '
      'under reduced motion', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.working, disableAnimations: true));
    await tester.pumpAndSettle(); // settles: no repeating ticker
    final dot = _dot(tester, AgentStatus.working);
    expect(
      tester.renderObject(_spinner),
      paints
        ..circle(color: dot.withValues(alpha: 0.24))
        ..arc(color: dot),
    );
  });

  testWidgets('blocked shows the localized "Needs you" pill', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.blocked));
    expect(find.text('Needs you'), findsOneWidget);

    await tester.pumpWidget(
      _app(AgentStatus.blocked, locale: const Locale('ja')),
    );
    await tester.pumpAndSettle();
    expect(find.text('あなたの返答待ち'), findsOneWidget);
  });

  testWidgets('done is a filled dot', (tester) async {
    await tester.pumpWidget(_app(AgentStatus.done));
    final d = _circle(tester);
    expect(d.shape, BoxShape.circle);
    expect(d.color, _dot(tester, AgentStatus.done));
    expect(d.border, isNull);
    expect(tester.getSize(find.byType(Container)), const Size(8, 8));
  });

  testWidgets('idle and unknown are a hollow ring', (tester) async {
    for (final status in [AgentStatus.idle, AgentStatus.unknown]) {
      await tester.pumpWidget(_app(status));
      final d = _circle(tester);
      expect(d.shape, BoxShape.circle);
      expect(d.color, isNull);
      expect((d.border! as Border).top.width, 1.5);
      expect(tester.getSize(find.byType(Container)), const Size(8, 8));
    }
  });

  testWidgets('announces the status', (tester) async {
    final semantics = tester.ensureSemantics();
    const labels = {
      AgentStatus.working: 'working',
      AgentStatus.blocked: 'waiting for you',
      AgentStatus.done: 'all done',
      AgentStatus.idle: 'resting',
    };
    for (final MapEntry(key: status, value: label) in labels.entries) {
      await tester.pumpWidget(_app(status, disableAnimations: true));
      expect(
        tester.getSemantics(find.byType(AgentStatusIndicator)).label,
        label,
        reason: '$status',
      );
    }
    semantics.dispose();
  });
}
