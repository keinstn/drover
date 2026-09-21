import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/widgets/agent_switcher_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _agentA = AgentInfo(
  paneId: 'wA:p1',
  workspaceId: 'wA',
  tabId: 'wA:t1',
  agent: 'claude',
  status: AgentStatus.idle,
  cwd: '/tmp/proj-a',
  focused: false,
);

const _agentB = AgentInfo(
  paneId: 'wB:p1',
  workspaceId: 'wB',
  tabId: 'wB:t1',
  agent: 'codex',
  status: AgentStatus.working,
  cwd: '/tmp/proj-b',
  focused: false,
);

/// Pumps the bar under a non-zero bottom safe-area inset, so "no inset at the
/// top anchor" is an assertion that can actually fail.
Widget _app({
  required List<AgentInfo> agents,
  String? currentPaneId,
  AgentSwitcherBarAnchor anchor = AgentSwitcherBarAnchor.bottom,
  int minAgents = 2,
  void Function(AgentInfo agent)? onSelect,
  VoidCallback? onOpenHerd,
  double bottomInset = 34,
}) {
  return MaterialApp(
    theme: droverDarkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(padding: EdgeInsets.only(bottom: bottomInset)),
        child: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AgentSwitcherBar(
                agents: agents,
                currentPaneId: currentPaneId,
                anchor: anchor,
                minAgents: minAgents,
                onSelect: onSelect ?? (_) {},
                onOpenHerd: onOpenHerd ?? () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The bar body: the one decorated container carrying the switcher ground.
BoxDecoration _barDecoration(WidgetTester tester) {
  final container = tester
      .widgetList<Container>(find.byType(Container))
      .firstWhere(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color ==
                droverDarkTheme.colorScheme.surfaceContainerLow,
      );
  return container.decoration as BoxDecoration;
}

EdgeInsets _barPadding(WidgetTester tester) {
  final container = tester
      .widgetList<Container>(find.byType(Container))
      .firstWhere(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color ==
                droverDarkTheme.colorScheme.surfaceContainerLow,
      );
  return container.padding! as EdgeInsets;
}

Border _ringOf(WidgetTester tester, String paneId) {
  final container = tester
      .widgetList<Container>(
        find.descendant(
          of: find.byKey(ValueKey('switcher_agent_$paneId')),
          matching: find.byType(Container),
        ),
      )
      .firstWhere((c) => c.foregroundDecoration is BoxDecoration);
  return (container.foregroundDecoration as BoxDecoration).border! as Border;
}

void main() {
  testWidgets(
    'the bottom anchor folds the safe-area inset into its padding and '
    'draws its hairline on top',
    (tester) async {
      await tester.pumpWidget(
        _app(agents: const [_agentA, _agentB], currentPaneId: 'wB:p1'),
      );
      await tester.pumpAndSettle();

      expect(_barPadding(tester), const EdgeInsets.fromLTRB(14, 9, 14, 9 + 34));
      final border = _barDecoration(tester).border! as Border;
      expect(border.top.color, droverDarkTheme.colorScheme.outlineVariant);
      expect(border.bottom, BorderSide.none);
    },
  );

  testWidgets(
    'the top anchor takes no safe-area inset and draws its hairline below',
    (tester) async {
      await tester.pumpWidget(
        _app(
          agents: const [_agentA, _agentB],
          currentPaneId: 'wB:p1',
          anchor: AgentSwitcherBarAnchor.top,
        ),
      );
      await tester.pumpAndSettle();

      // Plain 9 despite the 34px inset the harness supplies: the header above
      // has already cleared the safe area.
      expect(_barPadding(tester), const EdgeInsets.fromLTRB(14, 9, 14, 9));
      final border = _barDecoration(tester).border! as Border;
      expect(border.bottom.color, droverDarkTheme.colorScheme.outlineVariant);
      expect(border.top, BorderSide.none);
    },
  );

  testWidgets('the top anchor collapses to nothing when hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        agents: const [_agentA],
        currentPaneId: 'wA:p1',
        anchor: AgentSwitcherBarAnchor.top,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('switcher_herd_tab')), findsNothing);
    expect(
      tester.getSize(find.byType(AgentSwitcherBar)),
      const Size(800, 0),
      reason: 'no home-indicator clearance to keep under a header',
    );
  });

  testWidgets('minAgents: 1 shows the bar with a single agent', (tester) async {
    await tester.pumpWidget(
      _app(agents: const [_agentA], currentPaneId: null, minAgents: 1),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('switcher_herd_tab')), findsOneWidget);
    expect(find.byKey(const ValueKey('switcher_agent_wA:p1')), findsOneWidget);
  });

  testWidgets('the default gate still hides the bar with a single agent', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(agents: const [_agentA], currentPaneId: 'wA:p1'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('switcher_herd_tab')), findsNothing);
  });

  testWidgets(
    'currentPaneId: null rings nothing and leaves every cell tappable',
    (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        _app(
          agents: const [_agentA, _agentB],
          currentPaneId: null,
          onSelect: (agent) => selected.add(agent.paneId),
        ),
      );
      await tester.pumpAndSettle();

      // The transparent ring stays — it is what keeps the 44px footprint
      // identical whether or not a cell is current.
      expect(_ringOf(tester, 'wA:p1').top.color, Colors.transparent);
      expect(_ringOf(tester, 'wB:p1').top.color, Colors.transparent);

      final labelColors = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.style?.color)
          .toSet();
      expect(labelColors, isNot(contains(DroverColors.dark.accentText)));

      await tester.tap(find.byKey(const ValueKey('switcher_agent_wA:p1')));
      await tester.tap(find.byKey(const ValueKey('switcher_agent_wB:p1')));
      expect(selected, ['wA:p1', 'wB:p1']);
    },
  );
}
