import 'dart:math' as math;

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/widgets/agent_avatar.dart';
import 'package:drover/src/widgets/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One 0-255 channel from a [Color]'s 0.0-1.0 component.
int _channel(double component) => (component * 255).round();

/// WCAG relative luminance of [color], from its 0.0-1.0 components.
double _luminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG contrast ratio between [a] and [b], lighter over darker.
double _contrast(Color a, Color b) {
  final x = _luminance(a);
  final y = _luminance(b);
  final (hi, lo) = x > y ? (x, y) : (y, x);
  return (hi + 0.05) / (lo + 0.05);
}

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

    test('neither theme pins a font family of its own', () {
      // The themes use the platform face — SF Pro on iOS/macOS, Hiragino Sans
      // for Japanese — instead of the rounded gothic they used to set, which
      // was the largest single contributor to the old friendly read.
      //
      // Asserted against a bare ThemeData rather than `null`, because
      // Typography fills the family in per target platform ('Roboto' under
      // the test binding), so `null` would only pass by accident of platform.
      expect(
        droverDarkTheme.textTheme.bodyMedium?.fontFamily,
        ThemeData(brightness: Brightness.dark).textTheme.bodyMedium?.fontFamily,
      );
      expect(
        droverLightTheme.textTheme.bodyMedium?.fontFamily,
        ThemeData(
          brightness: Brightness.light,
        ).textTheme.bodyMedium?.fontFamily,
      );
    });

    test('dark tokens match the spec', () {
      final scheme = droverDarkTheme.colorScheme;
      expect(scheme.primary, const Color(0xFFEAE8EE));
      expect(scheme.surface, const Color(0xFF17171A));
      expect(droverDarkTheme.scaffoldBackgroundColor, scheme.surface);

      final colors = droverDarkTheme.extension<DroverColors>()!;
      expect(colors.statusDot(AgentStatus.blocked), const Color(0xFFE5695E));
      expect(colors.userBubble, const Color(0xFF33333A));
      expect(colors.brandColor('claude'), const Color(0xFFD9825F));
      expect(colors.brandColor('pi'), const Color(0xFFB98AC9));
      expect(colors.brandColor('omp'), const Color(0xFF55AAB9));
      expect(colors.brandColor('omp'), isNot(colors.brandFallback));
      // unknown status reuses the idle triple.
      expect(
        colors.statusDot(AgentStatus.unknown),
        colors.statusDot(AgentStatus.idle),
      );
    });

    test('light tokens match the spec', () {
      final scheme = droverLightTheme.colorScheme;
      expect(scheme.primary, const Color(0xFF1F1F22));
      expect(scheme.surface, const Color(0xFFFFFFFF));

      final colors = droverLightTheme.extension<DroverColors>()!;
      expect(colors.statusDot(AgentStatus.blocked), const Color(0xFFC73E3E));
      expect(colors.userBubble, const Color(0xFFD8D8DE));
      // Brand colors are identical across themes.
      expect(colors.brandColor('codex'), const Color(0xFF6FA287));
      expect(colors.brandColor('pi'), const Color(0xFFB98AC9));
      expect(colors.brandColor('pi'), isNot(colors.brandFallback));
      expect(colors.brandColor('omp'), const Color(0xFF55AAB9));
      expect(colors.brandColor('omp'), isNot(colors.brandFallback));
      // Unknown/null agent type falls back to a neutral tone.
      expect(colors.brandColor(null), const Color(0xFF7E7E83));
    });

    test('light neutrals stay near-neutral', () {
      final scheme = droverLightTheme.colorScheme;
      final colors = droverLightTheme.extension<DroverColors>()!;
      // The whole surface family, not just the steps currently read by a
      // widget: anything left to ColorScheme.fromSeed comes back chromatic,
      // and the seed's own surfaceContainerHighest was pink. Keep this list
      // exhaustive so a token nobody uses today can't reintroduce the cast
      // the day someone reaches for it.
      final neutrals = <String, Color>{
        // Under the ink accent `primary` belongs in this list rather than
        // being the exception to it: the accent has no hue of its own.
        'primary': scheme.primary,
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
        // top_toast. Excluded when this test was written, on the grounds that
        // a dark overlay is an island — but the app's two other fixed-dark
        // panels are cool, so the toast's seed-generated brown was the odd
        // one out among drover's own dark surfaces, not just against iOS.
        'inverseSurface': scheme.inverseSurface,
        'onInverseSurface': scheme.onInverseSurface,
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
        // even a trace cast over a large field is visible. Chroma stays within
        // 6/255 …
        expect(
          _chroma(color),
          lessThanOrEqualTo(6),
          reason: '$name carries too much chroma to read as neutral',
        );
        // … and what remains leans cool, never warm. This is the inverse of
        // the assertion this test shipped with: the light theme now sits on
        // iOS's axis, where "neutral" means faintly blue.
        expect(
          _channel(color.b),
          greaterThanOrEqualTo(_channel(color.r)),
          reason: '$name drifted to a warm cast',
        );
      });

      // Guard against neutralising the whole palette. `primary` used to be
      // the one deliberately chromatic token here; under the ink accent it is
      // deliberately achromatic (asserted above), so the semantic colours are
      // now the *only* thing standing between this theme and a grey app. They
      // have to stay readable as colour.
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

    test('the light elevation ladder descends from a pure white page', () {
      final scheme = droverLightTheme.colorScheme;
      // The page is the app icon's own white, and every container step recedes
      // from it — the inverse of Material's default. Assert the direction, not
      // just the values, so restoring a tinted page with raised white cards
      // fails here rather than passing the chroma guard unnoticed.
      expect(scheme.surface, const Color(0xFFFFFFFF));
      final descending = [
        ('surfaceContainerLowest', scheme.surfaceContainerLowest),
        ('surfaceContainerLow', scheme.surfaceContainerLow),
        ('surfaceContainer', scheme.surfaceContainer),
        ('surfaceContainerHigh', scheme.surfaceContainerHigh),
        ('surfaceContainerHighest', scheme.surfaceContainerHighest),
      ];
      var previous = _channel(scheme.surface.g);
      for (final (name, color) in descending) {
        final level = _channel(color.g);
        expect(
          level,
          lessThanOrEqualTo(previous),
          reason:
              '$name is brighter than the step above it — the ladder only '
              'reads as recessed panels if it descends monotonically',
        );
        previous = level;
      }
      // Cards have to differ from the page by a fill, not just their 1px
      // outline: on device the outline alone did not hold the grouping.
      expect(
        _channel(scheme.surface.g) - _channel(scheme.surfaceContainer.g),
        greaterThanOrEqualTo(4),
        reason: 'herd cards lost the fill difference that separates them',
      );
    });

    test('semantic pill backgrounds are tinted but never a wash', () {
      final colors = droverLightTheme.extension<DroverColors>()!;
      for (final status in [
        AgentStatus.blocked,
        AgentStatus.working,
        AgentStatus.done,
      ]) {
        final bg = colors.statusPillBg(status);
        // Low enough that it reads as a tint on the cool ground rather than a
        // loose colored card — this is what the old warm-ground values were.
        expect(
          _chroma(bg),
          lessThanOrEqualTo(15),
          reason: '$status pill background is washing the ground again',
        );
        // …but high enough to still say which status it is at a glance.
        expect(
          _chroma(bg),
          greaterThanOrEqualTo(5),
          reason: '$status pill background lost its hue',
        );
      }
    });

    test('text selection stays readable under the ink accent', () {
      // On iOS the selection colour comes from `CupertinoTheme.primaryColor`,
      // i.e. `colorScheme.primary` — near-white under ink, which dropped
      // selected text in the dark transcript to 3.43:1. Both themes pin
      // `textSelectionTheme` instead. Assert the readable result, not the
      // recipe, so any future accent change has to keep copy legible.
      for (final (name, theme, ground, ink) in [
        ('dark', droverDarkTheme, const Color(0xFF33333A), const Color(0xFFEAE8EE)),
        ('light', droverLightTheme, const Color(0xFFD8D8DE), const Color(0xFF1F1F22)),
      ]) {
        final selection = theme.textSelectionTheme.selectionColor;
        expect(selection, isNotNull, reason: '$name pins no selection colour');
        final highlighted = Color.alphaBlend(selection!, ground);
        expect(
          _contrast(ink, highlighted),
          greaterThanOrEqualTo(4.5),
          reason: '$name selected text in the user bubble is unreadable',
        );
        // …and the highlight has to be visible as a highlight.
        expect(
          _contrast(highlighted, ground),
          greaterThan(1.2),
          reason: '$name selection does not read as a highlight',
        );
      }
    });

    test('the user bubble stays distinct from the grey lozenges', () {
      // A regression guard, NOT a sufficiency proof. 1.20:1 is well under the
      // 3:1 usually wanted between adjacent non-text fills; what actually
      // identifies the bubble is its right alignment and its clipped-corner
      // tail, and the fill is a supporting cue. The old design carried this on
      // hue, which is why it needed no help. The threshold sits above the
      // 1.08:1 first tried for light — a genuine grey-on-grey collision — so
      // this catches that mistake coming back and nothing subtler.
      for (final (name, theme) in [
        ('dark', droverDarkTheme),
        ('light', droverLightTheme),
      ]) {
        final colors = theme.extension<DroverColors>()!;
        expect(
          _contrast(colors.userBubble, colors.toolSurface),
          greaterThan(1.15),
          reason: '$name user bubble is too close to the code lozenge to read '
              'as a different kind of thing',
        );
      }
    });

    test('no unpinned scheme role smuggles a hue back in', () {
      // `fromSeed` defaults to `tonalSpot`, which takes the seed's hue and
      // forces its own chroma — so a near-achromatic seed alone left
      // `secondary`/`tertiary` at chroma 27-41. Both themes ask for
      // `DynamicSchemeVariant.monochrome` instead. Nothing reads these roles
      // today, which is exactly why it needs a test: the next widget that
      // reaches for one should not be the thing that reintroduces a brand
      // colour. The error family is excluded — it is semantic and must stay
      // chromatic.
      for (final (name, theme) in [
        ('dark', droverDarkTheme),
        ('light', droverLightTheme),
      ]) {
        final scheme = theme.colorScheme;
        final unpinned = <String, Color>{
          'secondary': scheme.secondary,
          'onSecondary': scheme.onSecondary,
          'secondaryContainer': scheme.secondaryContainer,
          'onSecondaryContainer': scheme.onSecondaryContainer,
          'tertiary': scheme.tertiary,
          'onTertiary': scheme.onTertiary,
          'tertiaryContainer': scheme.tertiaryContainer,
          'onTertiaryContainer': scheme.onTertiaryContainer,
          'primaryContainer': scheme.primaryContainer,
          'onPrimaryContainer': scheme.onPrimaryContainer,
        };
        unpinned.forEach((role, color) {
          expect(
            _chroma(color),
            lessThanOrEqualTo(2),
            reason: '$name $role carries a hue; the ink palette has none to give',
          );
        });
        // The counterweight: `error` stays a real red, or the app loses the
        // one colour that says a destructive action is destructive.
        expect(_chroma(scheme.error), greaterThan(100), reason: name);
      }
    });

    test('the accent carries no hue of its own', () {
      for (final (name, theme) in [
        ('dark', droverDarkTheme),
        ('light', droverLightTheme),
      ]) {
        final scheme = theme.colorScheme;
        final colors = theme.extension<DroverColors>()!;

        // The point of the ink accent: it is the page's own ink, so the fill
        // role, the text role and body copy are all one value. A hue
        // reappearing here means someone reintroduced a brand colour.
        expect(
          _chroma(scheme.primary),
          lessThanOrEqualTo(6),
          reason: '$name primary picked up a hue; the accent is meant to be ink',
        );
        expect(colors.accentText, scheme.onSurface, reason: name);
        expect(colors.accentText, scheme.primary, reason: name);

        // Which is why no *text* action may rely on the accent to look
        // tappable — see the underline in demo_screen and the weight in
        // structured_prompt_sheet. Selection marks are the legitimate use.
        expect(colors.accentText, isNot(colors.tertiaryText), reason: name);

        // The one thing the accent must still clear: it sits beside five agent
        // brand colours and must not be mistaken for any of them.
        for (final agent in ['claude', 'codex', 'copilot', 'pi', 'omp']) {
          expect(
            colors.brandColor(agent),
            isNot(scheme.primary),
            reason: '$name accent collides with $agent',
          );
        }
      }
    });

    test('rgba pill backgrounds carry the spec alpha (dark)', () {
      final colors = droverDarkTheme.extension<DroverColors>()!;
      expect(
        colors.statusPillBg(AgentStatus.blocked),
        const Color.fromRGBO(229, 105, 94, 0.12),
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

      // π, not the fallback's `P` — that would be indistinguishable from
      // copilot.
      await pump(tester, 'pi');
      expect(find.text('π'), findsOneWidget);
      expect(find.text('P'), findsNothing);
    });

    testWidgets('falls back to first letter and ? for unknown', (tester) async {
      await pump(tester, 'gemini');
      expect(find.text('G'), findsOneWidget);

      // omp has no case arm on purpose: the fallback's first letter is `O`,
      // which is already unique among the five known agents.
      await pump(tester, 'omp');
      expect(find.text('O'), findsOneWidget);

      await pump(tester, null);
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('rounds its corners at the control radius', (tester) async {
      await pump(tester, 'claude');

      final decoration =
          tester
                  .widget<Container>(
                    find.descendant(
                      of: find.byType(AgentAvatar),
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        decoration.borderRadius,
        BorderRadius.circular(droverRadiusControl),
      );
    });
  });

  group('geometry', () {
    test('the radius vocabulary is 6/4/2 and nothing else', () {
      // Other units build every corner in the app out of these three, so a
      // drift here silently restyles the whole surface area.
      expect(droverRadiusPanel, 6.0);
      expect(droverRadiusControl, 4.0);
      expect(droverRadiusChip, 2.0);
    });

    /// The widest corner [shape] draws, and a failure for anything outside the
    /// vocabulary. Shape *type* is checked before radius on purpose: a
    /// [StadiumBorder] or a [CircleBorder] carries no `borderRadius` at all
    /// and would sail past a radius comparison.
    double widestCorner(String name, ShapeBorder? shape) {
      if (shape == null) {
        fail(
          '$name pins no shape — that component is back on the Material '
          'default, which is where the round geometry lives',
        );
      }
      final geometry = switch (shape) {
        RoundedRectangleBorder(:final borderRadius) => borderRadius,
        UnderlineInputBorder(:final borderRadius) => borderRadius,
        _ => null,
      };
      if (geometry == null) {
        fail(
          '$name resolves to ${shape.runtimeType}, which is not one of the '
          'ink shapes',
        );
      }
      final radius = geometry.resolve(TextDirection.ltr);
      return [
        radius.topLeft,
        radius.topRight,
        radius.bottomLeft,
        radius.bottomRight,
      ].expand((r) => [r.x, r.y]).reduce((a, b) => a > b ? a : b);
    }

    /// Every component theme the app pins, by name, with the shapes it
    /// resolves to. Buttons resolve per widget state, so each is sampled in
    /// the states a stadium could be reintroduced on.
    Map<String, List<ShapeBorder?>> pinnedShapes(ThemeData theme) {
      List<ShapeBorder?> perState(
        WidgetStateProperty<OutlinedBorder?>? shape,
      ) => [
        for (final states in const [
          <WidgetState>{},
          {WidgetState.disabled},
          {WidgetState.pressed},
          {WidgetState.focused},
        ])
          shape?.resolve(states),
      ];
      return {
        'filledButtonTheme': perState(theme.filledButtonTheme.style?.shape),
        'outlinedButtonTheme': perState(theme.outlinedButtonTheme.style?.shape),
        'textButtonTheme': perState(theme.textButtonTheme.style?.shape),
        'elevatedButtonTheme': perState(theme.elevatedButtonTheme.style?.shape),
        'iconButtonTheme': perState(theme.iconButtonTheme.style?.shape),
        'floatingActionButtonTheme': [theme.floatingActionButtonTheme.shape],
        'dialogTheme': [theme.dialogTheme.shape],
        'cardTheme': [theme.cardTheme.shape],
        'bottomSheetTheme': [theme.bottomSheetTheme.shape],
        'chipTheme': [theme.chipTheme.shape],
        'inputDecorationTheme': [theme.inputDecorationTheme.border],
      };
    }

    test('no component theme keeps a round Material default', () {
      // The point of the component themes: Material 3's own defaults are
      // stadium buttons and icon buttons, a 28-radius dialog and bottom sheet,
      // a 12-radius card, an 8-radius chip. A call site nobody enumerated
      // inherits whatever is set here, so a re-added pill — or a component
      // theme dropped in a refactor — has to fail here rather than on a device.
      for (final theme in [droverDarkTheme, droverLightTheme]) {
        pinnedShapes(theme).forEach((component, shapes) {
          for (final shape in shapes) {
            expect(
              widestCorner('${theme.brightness.name} $component', shape),
              lessThanOrEqualTo(droverRadiusPanel),
            );
          }
        });
      }
    });

    test('the neutral button is one shared style, and is opt-in', () {
      // It used to be a `_neutralButtonStyle` helper copy-pasted into two
      // screens. One definition now — but a style rather than
      // `outlinedButtonTheme`, because a themed fill would reach every
      // OutlinedButton, including the key caps that §8 keeps unfilled.
      const enabled = <WidgetState>{};
      for (final theme in [droverDarkTheme, droverLightTheme]) {
        final scheme = theme.colorScheme;
        final neutral = droverNeutralButtonStyle(scheme);
        expect(
          neutral.backgroundColor?.resolve(enabled),
          scheme.surfaceContainerHigh,
        );
        expect(neutral.side?.resolve(enabled)?.color, scheme.outline);

        final themed = theme.outlinedButtonTheme.style!;
        expect(themed.backgroundColor?.resolve(enabled), isNull);
        expect(themed.side?.resolve(enabled)?.color, scheme.outline);
      }
    });

    test('the outline resolves per state, not flat', () {
      // A flat `BorderSide` beats Material's own `resolveWith` default, so it
      // would leave a disabled button with a full-contrast border around a
      // dimmed label, and strip every OutlinedButton's focus ring (iPad,
      // external keyboard). Alpha rather than channel values: the disabled
      // edge is `onSurface` at 12%, which isn't orderable against an opaque
      // `outline` any other way.
      const enabled = <WidgetState>{};
      for (final theme in [droverDarkTheme, droverLightTheme]) {
        final scheme = theme.colorScheme;
        for (final side in [
          theme.outlinedButtonTheme.style!.side!,
          droverNeutralButtonStyle(scheme).side!,
        ]) {
          expect(side.resolve(enabled)!.color.a, 1.0);
          expect(
            side.resolve({WidgetState.disabled})!.color.a,
            lessThan(side.resolve(enabled)!.color.a),
            reason: 'a disabled border must dim with its label',
          );
          expect(
            side.resolve({WidgetState.focused})!.color,
            scheme.primary,
            reason: 'the focus ring is the only keyboard affordance here',
          );
        }
      }
    });
  });

  group('label ramp', () {
    /// A context under [locale], for the two helpers that read
    /// [Localizations.localeOf].
    Future<BuildContext> contextFor(WidgetTester tester, String locale) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox(key: ValueKey('probe')),
        ),
      );
      await tester.pumpAndSettle();
      return tester.element(find.byKey(const ValueKey('probe')));
    }

    testWidgets('is mono, tracked and uppercased outside Japanese', (
      tester,
    ) async {
      final context = await contextFor(tester, 'en');

      final style = droverLabelStyle(context);
      expect(style.fontFamily, droverMonoFamily);
      expect(style.fontSize, 9.5);
      expect(style.fontWeight, FontWeight.w500);
      expect(style.letterSpacing, closeTo(9.5 * 0.08, 0.001));
      expect(droverLabelText(context, 'workspaces'), 'WORKSPACES');

      // Callers that need a louder label (the primary button) pass their own
      // weight and colour; those must win over the ramp's defaults.
      final loud = droverLabelStyle(
        context,
        fontSize: 11.5,
        color: const Color(0xFFFFFFFF),
        weight: FontWeight.w700,
      );
      expect(loud.fontWeight, FontWeight.w700);
      expect(loud.fontSize, 11.5);
      expect(loud.color, const Color(0xFFFFFFFF));
      expect(loud.letterSpacing, closeTo(11.5 * 0.08, 0.001));
    });

    testWidgets('drops mono and gains weight in Japanese', (tester) async {
      final context = await contextFor(tester, 'ja');

      final style = droverLabelStyle(context);
      // [droverMonoFamily] has no Japanese coverage, so ja falls through to
      // the platform gothic, half a point larger and a step heavier because
      // CJK strokes thin out at the ramp's sizes.
      expect(style.fontFamily, isNull);
      expect(style.fontSize, 10.0);
      expect(style.fontWeight, FontWeight.w600);
      expect(
        style.fontWeight!.value,
        greaterThan(FontWeight.w500.value),
        reason: 'ja must stay heavier than the Latin ramp, not lighter',
      );
      // Tracking is gentler, and computed off the requested size, not the
      // bumped one.
      expect(style.letterSpacing, closeTo(9.5 * 0.045, 0.001));

      // No case change: full-width glyphs have none, and uppercasing the
      // ASCII embedded in a Japanese label would single it out.
      expect(droverLabelText(context, 'workspaces'), 'workspaces');
    });
  });

  group('StatusPill', () {
    /// Pumps a chip under [locale], with the delegates the label case needs.
    Future<void> pump(WidgetTester tester, String locale) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          theme: droverDarkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(child: StatusPill(status: AgentStatus.blocked)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The chip's outer container, then its LED, in tree order.
    List<Container> containers(WidgetTester tester) => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(StatusPill),
            matching: find.byType(Container),
          ),
        )
        .toList();

    testWidgets('renders the chip colors, radius and border', (tester) async {
      await pump(tester, 'ja');

      final colors = droverDarkTheme.extension<DroverColors>()!;
      final decoration = containers(tester).first.decoration! as BoxDecoration;
      expect(decoration.color, colors.statusPillBg(AgentStatus.blocked));
      expect(decoration.borderRadius, BorderRadius.circular(droverRadiusChip));

      // The hairline is derived from the dot, not from a neutral outline: it
      // is what gives the chip an edge over a 12%-alpha fill.
      final border = decoration.border! as Border;
      final dot = colors.statusDot(AgentStatus.blocked);
      expect(border.top.width, 1);
      expect(_channel(border.top.color.r), _channel(dot.r));
      expect(_channel(border.top.color.g), _channel(dot.g));
      expect(_channel(border.top.color.b), _channel(dot.b));
      expect(border.top.color.a, closeTo(0.34, 0.005));
    });

    testWidgets('draws the dot as a square LED, not a bullet', (tester) async {
      await pump(tester, 'ja');

      final dot = containers(tester).last;
      expect(dot.constraints?.maxWidth, 5);
      expect(dot.constraints?.maxHeight, 5);
      // A plain colored box: no BoxDecoration means no BoxShape.circle to
      // round it back into a bullet.
      expect(dot.decoration, isNull);
      expect(
        dot.color,
        droverDarkTheme.extension<DroverColors>()!.statusDot(
          AgentStatus.blocked,
        ),
      );
    });

    testWidgets('uppercases the label in English but not in Japanese', (
      tester,
    ) async {
      await pump(tester, 'en');
      // Presentational only — the ARB string itself stays lowercase.
      expect(find.text('WAITING FOR YOU'), findsOneWidget);

      await pump(tester, 'ja');
      // Full-width glyphs have no case, so the localized copy renders as-is.
      expect(find.text('返事待ち'), findsOneWidget);
    });
  });
}
