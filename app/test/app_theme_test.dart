import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/widgets/agent_avatar.dart';
import 'package:drover/src/widgets/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DroverColors extension', () {
    test('both themes register a DroverColors extension', () {
      expect(droverDarkTheme.extension<DroverColors>(), isNotNull);
      expect(droverLightTheme.extension<DroverColors>(), isNotNull);
    });

    test('both themes use the rounded-gothic fallback font', () {
      expect(
        droverDarkTheme.textTheme.bodyMedium?.fontFamily,
        'Hiragino Maru Gothic ProN',
      );
      expect(
        droverLightTheme.textTheme.bodyMedium?.fontFamily,
        'Hiragino Maru Gothic ProN',
      );
    });

    test('dark tokens match the spec', () {
      final scheme = droverDarkTheme.colorScheme;
      expect(scheme.primary, const Color(0xFF74B25C));
      expect(scheme.surface, const Color(0xFF151815));
      expect(droverDarkTheme.scaffoldBackgroundColor, scheme.surface);

      final colors = droverDarkTheme.extension<DroverColors>()!;
      expect(colors.statusDot(AgentStatus.blocked), const Color(0xFFE8705A));
      expect(colors.userBubble, const Color(0xFF2C332B));
      expect(colors.brandColor('claude'), const Color(0xFFC9743F));
      // unknown status reuses the idle triple.
      expect(
        colors.statusDot(AgentStatus.unknown),
        colors.statusDot(AgentStatus.idle),
      );
    });

    test('light tokens match the spec', () {
      final scheme = droverLightTheme.colorScheme;
      expect(scheme.primary, const Color(0xFF3F7D39));
      expect(scheme.surface, const Color(0xFFF5F3EB));

      final colors = droverLightTheme.extension<DroverColors>()!;
      expect(colors.statusDot(AgentStatus.blocked), const Color(0xFFC25742));
      expect(colors.userBubble, const Color(0xFFE6E7DD));
      // Brand colors are identical across themes.
      expect(colors.brandColor('codex'), const Color(0xFF4E93B0));
      // Unknown/null agent type falls back to a neutral tone.
      expect(colors.brandColor(null), const Color(0xFF6B7268));
    });

    test('rgba pill backgrounds carry the spec alpha (dark)', () {
      final colors = droverDarkTheme.extension<DroverColors>()!;
      expect(
        colors.statusPillBg(AgentStatus.blocked),
        const Color.fromRGBO(232, 112, 90, 0.16),
      );
    });
  });

  group('AgentAvatar', () {
    Future<void> pump(WidgetTester tester, String? agent) => tester.pumpWidget(
      MaterialApp(
        theme: droverDarkTheme,
        home: Scaffold(
          body: Center(child: AgentAvatar(agent: agent)),
        ),
      ),
    );

    testWidgets('renders the mapped initial per agent type', (tester) async {
      await pump(tester, 'claude');
      expect(find.text('C'), findsOneWidget);

      await pump(tester, 'codex');
      expect(find.text('X'), findsOneWidget);

      await pump(tester, 'copilot');
      expect(find.text('P'), findsOneWidget);
    });

    testWidgets('falls back to first letter and ? for unknown', (tester) async {
      await pump(tester, 'gemini');
      expect(find.text('G'), findsOneWidget);

      await pump(tester, null);
      expect(find.text('?'), findsOneWidget);
    });
  });

  group('StatusPill', () {
    testWidgets('renders the localized label and pill colors', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ja'),
          theme: droverDarkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(child: StatusPill(status: AgentStatus.blocked)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Localized human copy for `blocked` in Japanese.
      expect(find.text('返事待ち'), findsOneWidget);

      final colors = droverDarkTheme.extension<DroverColors>()!;
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(StatusPill),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, colors.statusPillBg(AgentStatus.blocked));
    });
  });
}
