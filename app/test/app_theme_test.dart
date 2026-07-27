import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/widgets/agent_avatar.dart';
import 'package:drover/src/widgets/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One 0-255 channel from a [Color]'s 0.0-1.0 component.
int _channel(double component) => (component * 255).round();

/// Rough chroma proxy: the spread between a color's widest channels, in
/// 0-255 units. 0 is fully achromatic.
int _chroma(Color color) {
  final channels = [_channel(color.r), _channel(color.g), _channel(color.b)];
  return channels.reduce((a, b) => a > b ? a : b) -
      channels.reduce((a, b) => a < b ? a : b);
}

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
      expect(scheme.primary, const Color(0xFFE0956B));
      expect(scheme.surface, const Color(0xFF191511));
      expect(droverDarkTheme.scaffoldBackgroundColor, scheme.surface);

      final colors = droverDarkTheme.extension<DroverColors>()!;
      expect(colors.statusDot(AgentStatus.blocked), const Color(0xFFE86A55));
      expect(colors.userBubble, const Color(0xFF3A2E22));
      expect(colors.brandColor('claude'), const Color(0xFFD9825F));
      // unknown status reuses the idle triple.
      expect(
        colors.statusDot(AgentStatus.unknown),
        colors.statusDot(AgentStatus.idle),
      );
    });

    test('light tokens match the spec', () {
      final scheme = droverLightTheme.colorScheme;
      expect(scheme.primary, const Color(0xFFC2704E));
      expect(scheme.surface, const Color(0xFFF7F6F4));

      final colors = droverLightTheme.extension<DroverColors>()!;
      expect(colors.statusDot(AgentStatus.blocked), const Color(0xFFC75B44));
      expect(colors.userBubble, const Color(0xFFF0E2D0));
      // Brand colors are identical across themes.
      expect(colors.brandColor('codex'), const Color(0xFF6FA287));
      // Unknown/null agent type falls back to a neutral tone.
      expect(colors.brandColor(null), const Color(0xFF837F7A));
    });

    test('light neutrals stay near-neutral', () {
      final scheme = droverLightTheme.colorScheme;
      final colors = droverLightTheme.extension<DroverColors>()!;
      // The whole surface family, not just the steps currently read by a
      // widget: anything left to ColorScheme.fromSeed comes back chromatic,
      // and the seed's own surfaceContainerHighest was pink. Keep this list
      // exhaustive so a token nobody uses today can't reintroduce the cast
      // the day someone reaches for it. inverseSurface/onInverseSurface are
      // deliberately absent — the toast is a dark island in either theme.
      final neutrals = <String, Color>{
        'surface': scheme.surface,
        'surfaceBright': scheme.surfaceBright,
        'surfaceDim': scheme.surfaceDim,
        'surfaceContainerLowest': scheme.surfaceContainerLowest,
        'surfaceContainerLow': scheme.surfaceContainerLow,
        'surfaceContainer': scheme.surfaceContainer,
        'surfaceContainerHigh': scheme.surfaceContainerHigh,
        'surfaceContainerHighest': scheme.surfaceContainerHighest,
        'onSurface': scheme.onSurface,
        'onSurfaceVariant': scheme.onSurfaceVariant,
        'outline': scheme.outline,
        'outlineVariant': scheme.outlineVariant,
        'toolSurface': colors.toolSurface,
        'tertiaryText': colors.tertiaryText,
        // Not grounds, but tokens whose whole job is to signal the absence of
        // a state or a brand — they have to look as neutral as they mean.
        'idleDot': colors.idleDot,
        'idlePillBg': colors.idlePillBg,
        'idlePillFg': colors.idlePillFg,
        'brandFallback': colors.brandFallback,
      };

      neutrals.forEach((name, color) {
        // On device nothing achromatic shares the screen to judge against, so
        // even a trace cast over a large field reads warm. Chroma stays within
        // 9/255 …
        expect(
          _chroma(color),
          lessThanOrEqualTo(9),
          reason: '$name carries too much chroma to read as neutral',
        );
        // … and what remains still leans warm, never cool.
        expect(
          _channel(color.r),
          greaterThanOrEqualTo(_channel(color.b)),
          reason: '$name drifted to a cool cast',
        );
      });

      // Guard against neutralising the whole palette: primary is the one
      // deliberately chromatic token on the light ground, and the statuses
      // that do carry meaning have to stay readable as color.
      expect(_chroma(scheme.primary), greaterThan(100));
      for (final status in [
        AgentStatus.blocked,
        AgentStatus.working,
        AgentStatus.done,
      ]) {
        expect(
          _chroma(colors.statusDot(status)),
          greaterThan(40),
          reason: '$status is a semantic color and must not be neutralised',
        );
      }
    });

    test('rgba pill backgrounds carry the spec alpha (dark)', () {
      final colors = droverDarkTheme.extension<DroverColors>()!;
      expect(
        colors.statusPillBg(AgentStatus.blocked),
        const Color.fromRGBO(232, 106, 85, 0.16),
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
