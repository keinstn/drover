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

/// Pumps the bar under a non-zero bottom safe-area inset, so folding it into
/// the padding is an assertion that can actually fail.
Widget _app({
  required List<AgentInfo> agents,
  required String currentPaneId,
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

void main() {
  testWidgets('the bar folds the safe-area inset into its padding and '
      'draws its hairline on top', (tester) async {
    await tester.pumpWidget(
      _app(agents: const [_agentA, _agentB], currentPaneId: 'wB:p1'),
    );
    await tester.pumpAndSettle();

    expect(_barPadding(tester), const EdgeInsets.fromLTRB(14, 9, 14, 9 + 34));
    final border = _barDecoration(tester).border! as Border;
    expect(border.top.color, droverDarkTheme.colorScheme.outlineVariant);
    expect(border.bottom, BorderSide.none);
  });

  testWidgets('hides the bar with a single agent', (tester) async {
    await tester.pumpWidget(
      _app(agents: const [_agentA], currentPaneId: 'wA:p1'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('switcher_herd_tab')), findsNothing);
  });
}
