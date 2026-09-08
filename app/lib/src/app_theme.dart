import 'package:flutter/material.dart';

import 'models/agent_info.dart';

// Geometry. These three are the whole radius vocabulary: nothing keeps a
// stadium, a circle, or a radius above 6. The sharp corners are most of what
// separates the ink read from the friendly one they replaced.
const droverRadiusPanel = 6.0; // card, sheet, panel, code block
const droverRadiusControl = 4.0; // button, input, avatar, icon button
const droverRadiusChip = 2.0; // chip, badge, status pill, key cap

/// Monospace family for code, terminal output and the label ramp. One seam on
/// purpose: bundling a real face (JetBrains Mono) is a follow-up, and when it
/// lands it changes here rather than at every call site.
const droverMonoFamily = 'monospace';

/// Uppercases [text] outside Japanese. Uppercase is a Latin device: full-width
/// glyphs have no case, and the tracking that makes caps legible collides them.
/// Use this instead of calling `toUpperCase()` on a localized string.
String droverLabelText(BuildContext context, String text) =>
    Localizations.localeOf(context).languageCode == 'ja'
    ? text
    : text.toUpperCase();

/// The label ramp: mono, uppercase-tracked, small — status chips, section and
/// workspace headers, host lines, key caps.
///
/// In Japanese it becomes the platform gothic instead ([droverMonoFamily] has
/// no Japanese coverage), half a point larger at a heavier weight because CJK
/// strokes thin out at these sizes, and with gentler tracking. Sizes in use:
/// 9.0 status chip / elapsed, 9.5 headers and filter chips, 10.5 host line and
/// key caps.
TextStyle droverLabelStyle(
  BuildContext context, {
  double fontSize = 9.5,
  Color? color,
  FontWeight? weight,
}) {
  final ja = Localizations.localeOf(context).languageCode == 'ja';
  return TextStyle(
    fontFamily: ja ? null : droverMonoFamily,
    fontSize: ja ? fontSize + 0.5 : fontSize,
    fontWeight: weight ?? (ja ? FontWeight.w600 : FontWeight.w500),
    // Proportional to the requested size, so the ramp tracks consistently.
    letterSpacing: fontSize * (ja ? 0.045 : 0.08),
    color: color,
  );
}

// The three radii as ready-made shapes, for the component themes in
// [_buildTheme] and nothing else: call sites keep using the constants.
const _panelShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(droverRadiusPanel)),
);
const _controlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(droverRadiusControl)),
);
const _chipShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(droverRadiusChip)),
);

/// The outline for [outlinedButtonTheme] and [droverNeutralButtonStyle],
/// resolved per widget state.
///
/// `OutlinedButton.styleFrom(side: …)` wraps a plain [BorderSide] in a
/// state-independent property, and a non-null theme value beats Material's
/// default — so a flat side would drop M3's dimmed disabled edge and its
/// focus ring app-wide, leaving a disabled button with a full-contrast border
/// around a dimmed label. Same three states M3 defines, with [ColorScheme
/// .outline] resting.
WidgetStateProperty<BorderSide> _droverOutlineSide(ColorScheme scheme) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return BorderSide(color: scheme.onSurface.withValues(alpha: 0.12));
      }
      if (states.contains(WidgetState.focused)) {
        return BorderSide(color: scheme.primary);
      }
      return BorderSide(color: scheme.outline);
    });

/// The neutral button: a filled-but-quiet alternative to the ink primary —
/// a `surfaceContainerHigh` fill plus a 1px `outline`, so it carries weight
/// without borrowing the accent.
///
/// Deliberately a shared style rather than `outlinedButtonTheme`, which would
/// fill *every* OutlinedButton: an OutlinedButton is a medium-emphasis
/// *unfilled* button, and agent_screen's key caps and tool chips depend on
/// staying unfilled.
ButtonStyle droverNeutralButtonStyle(ColorScheme scheme) =>
    OutlinedButton.styleFrom(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: _controlShape,
    ).copyWith(side: _droverOutlineSide(scheme));

/// Ink dark theme. The accent carries no hue at all: it is the page's own ink,
/// inverted into a fill. That is the rule the app icon already follows — drover
/// is black and white — and it means every colour on screen means something,
/// either which agent ([DroverColors.brandColor]) or what state
/// ([DroverColors.statusDot]). Nothing is coloured for decoration.
final ThemeData droverDarkTheme = _buildTheme(
  brightness: Brightness.dark,
  scheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFEAE8EE),
        brightness: Brightness.dark,
        // A near-achromatic *seed* is not enough: `fromSeed` defaults to
        // `tonalSpot`, which takes the seed's hue and forces its own chroma,
        // so `secondary`/`tertiary` came back at chroma 27-41 no matter what
        // was passed here. `monochrome` is what actually makes the roles this
        // theme does not pin come back grey. Nothing reads them today; this
        // keeps the next widget that does from reintroducing a hue.
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(
        surface: const Color(0xFF17171A),
        surfaceContainerLowest: const Color(0xFF131316),
        surfaceContainerLow: const Color(0xFF1B1B1F),
        surfaceContainer: const Color(0xFF1E1E22),
        surfaceContainerHigh: const Color(0xFF26262B),
        // Pinned rather than left to the seed, whose deepest step lands a
        // shade off the ladder the rest of these values describe.
        surfaceContainerHighest: const Color(0xFF2E2E33),
        onSurface: const Color(0xFFEAE8EE),
        onSurfaceVariant: const Color(0xFFB0AFB6),
        outline: const Color(0xFF35353D),
        // Deliberately equal to surfaceContainerHigh: dark had no panel
        // hairlines at all before, and on flat ink surfaces the line that
        // separates a panel is just the next step of the ladder.
        outlineVariant: const Color(0xFF26262B),
        // top_toast: the page inverted, rather than the seed's tinted pair.
        inverseSurface: const Color(0xFFEAE8EE),
        onInverseSurface: const Color(0xFF17171A),
        // [onSurface] over again: the accent is the ink. A filled primary is
        // therefore the highest-contrast control the palette can produce
        // (14.72:1 on `surface`), which is deliberate — it is also the only
        // thing on screen allowed to outrank the status colours.
        primary: const Color(0xFFEAE8EE),
        onPrimary: const Color(0xFF17171A),
        surfaceTint: const Color(0xFFEAE8EE),
        error: const Color(0xFFE5695E),
      ),
  colors: DroverColors.dark,
);

/// Light theme. Its neutrals sit on a faintly *cool* axis (R−B around −4)
/// rather than a strictly achromatic one.
///
/// That reads as arbitrary and is not. Three passes of pulling chroma out of
/// the light grounds (#130, #133) still came back as cream on device, because
/// on iOS "neutral" is normed cool: every system surface around drover is
/// `systemGroupedBackground` `#F2F2F7`. Against that, even a fully achromatic
/// ground reads slightly warm. So the light theme joins the platform's axis —
/// and since the ink accent has no hue either, the semantic status colours are
/// the only chroma left on this ground.
///
/// These values predate the ink dark theme and are unchanged by it — they were
/// tuned against iOS on device, not chosen to contrast with the warm dark
/// surfaces that used to sit opposite them.
///
/// Note the inverted elevation: [ColorScheme.surface] is the *brightest* light
/// token and the `surfaceContainer*` ladder descends from it. See the comment
/// on `surface` below.
final ThemeData droverLightTheme = _buildTheme(
  brightness: Brightness.light,
  scheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F1F22),
        brightness: Brightness.light,
        // As in the dark theme: the variant, not the seed, is what keeps the
        // unpinned roles grey.
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(
        // The elevation ladder runs *downwards*: the page is the icon's own
        // white and every container step recedes from it, rather than the
        // Material default of a tinted page with raised white cards. Keeping
        // the page at #FFFFFF was the requirement; the cards then need a fill
        // difference to stay legible as groups, and a 1px outline alone did
        // not survive on device. So they recede instead of rising.
        surface: const Color(0xFFFFFFFF),
        surfaceBright: const Color(0xFFFFFFFF),
        // Flush with the page: this is the transcript body, which should read
        // as the page itself rather than as a panel on it.
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        // The agent screen's bottom switcher bar — chrome, so barely off-page,
        // and it carries its own top border.
        surfaceContainerLow: const Color(0xFFFAFAFC),
        // Herd cards.
        surfaceContainer: const Color(0xFFF9F9FC),
        surfaceContainerHigh: const Color(0xFFF9F9FC),
        // The deepest step, and the only one that was already recessed before
        // the ladder flipped: the tonal button in agent_screen, which has to
        // read as filled. Left to the seed it comes out tinted.
        surfaceContainerHighest: const Color(0xFFE8E8EC),
        surfaceDim: const Color(0xFFE4E4E9),
        // Same lightness as the icon's black (`#1F1F1F`).
        onSurface: const Color(0xFF1F1F22),
        onSurfaceVariant: const Color(0xFF78787D),
        outline: const Color(0xFFE0E0E5),
        outlineVariant: const Color(0xFFDEDEE3),
        // top_toast's background and text. Previously left to the seed, which
        // made them warm brown/cream — the only warm dark surface in an app
        // whose two other fixed-dark panels (the transcript and code panels in
        // agent_screen) are both cool.
        inverseSurface: const Color(0xFF2C2C31),
        onInverseSurface: const Color(0xFFF2F2F5),
        // The ink accent inverted: on the white page it is the icon's own
        // near-black. Same lightness as [onSurface], so like dark it needs no
        // separate text/fill split.
        primary: const Color(0xFF1F1F22),
        onPrimary: const Color(0xFFFFFFFF),
        surfaceTint: const Color(0xFF1F1F22),
        error: const Color(0xFFC73E3E),
      ),
  colors: DroverColors.light,
);

ThemeData _buildTheme({
  required Brightness brightness,
  required ColorScheme scheme,
  required DroverColors colors,
}) => ThemeData(
  useMaterial3: true,
  brightness: brightness,
  colorScheme: scheme,
  scaffoldBackgroundColor: scheme.surface,
  // Pinned because the ink accent cannot serve here. On iOS the selection
  // colour comes from `CupertinoTheme.primaryColor`, which resolves to
  // `colorScheme.primary` — near-white under ink, which dropped selected text
  // in the dark transcript to 3.43:1. Long-pressing to copy an agent's reply
  // is a first-class drover action, so this is a visible break rather than a
  // theoretical one. `onSurfaceVariant` at 30% keeps selected text at 5.8:1 or
  // better on every ground while still reading as a highlight.
  textSelectionTheme: TextSelectionThemeData(
    selectionColor: scheme.onSurfaceVariant.withValues(alpha: 0.30),
  ),
  // No `fontFamily`: the platform face (SF Pro, Hiragino Sans for Japanese) is
  // the professional read. The rounded gothic that used to be set here was the
  // single largest contributor to the friendly one.
  //
  // Material 3's own component defaults are the geometry this redesign
  // replaces: stadium buttons and icon buttons, a 28-radius dialog and bottom
  // sheet, a 16-radius extended FAB, a 12-radius card, an 8-radius chip.
  // Pinning them here rather than at call sites is what keeps a widget nobody
  // enumerated from staying round — and `bottomSheetTheme` is the fix for the
  // sheets that paint their own panel, whose 28-radius shell used to peek out
  // around them as a second, mismatched corner.
  //
  // Shape only: none of these set padding, density or a minimum size, so every
  // control keeps the tap target Material gives it.
  filledButtonTheme: const FilledButtonThemeData(
    style: ButtonStyle(shape: WidgetStatePropertyAll(_controlShape)),
  ),
  textButtonTheme: const TextButtonThemeData(
    style: ButtonStyle(shape: WidgetStatePropertyAll(_controlShape)),
  ),
  elevatedButtonTheme: const ElevatedButtonThemeData(
    style: ButtonStyle(shape: WidgetStatePropertyAll(_controlShape)),
  ),
  // Shape and hairline only — no fill. An OutlinedButton is Material's
  // medium-emphasis *unfilled* button, and the key caps and tool chips in
  // agent_screen are built on that. The filled neutral treatment is opt-in via
  // [droverNeutralButtonStyle].
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: ButtonStyle(
      side: _droverOutlineSide(scheme),
      shape: const WidgetStatePropertyAll(_controlShape),
    ),
  ),
  iconButtonTheme: const IconButtonThemeData(
    style: ButtonStyle(shape: WidgetStatePropertyAll(_controlShape)),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    shape: _controlShape,
  ),
  dialogTheme: const DialogThemeData(shape: _panelShape),
  cardTheme: const CardThemeData(shape: _panelShape),
  bottomSheetTheme: const BottomSheetThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(droverRadiusPanel),
      ),
    ),
  ),
  chipTheme: const ChipThemeData(shape: _chipShape),
  // Already Material's own value — an underline rounded 4 at the top corners —
  // but pinned to the constant so inputs follow the vocabulary if that default
  // moves. Radius only: `InputDecorator` still `copyWith`s its per-state
  // border colors onto whatever border it is handed, so this stays inert for
  // everything but geometry.
  inputDecorationTheme: const InputDecorationThemeData(
    border: UnderlineInputBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(droverRadiusControl),
      ),
    ),
  ),
  extensions: [colors],
);

/// Deprecated alias kept so callers not yet migrated to the two-theme setup
/// keep compiling. Resolves to the dark theme (drover's original default).
final ThemeData droverTheme = droverDarkTheme;

// Legacy Ink accents still referenced by the AgentMode chip colors below and
// in agent_screen's mode switch. Agent-status colors now live per-brightness
// in [DroverColors]; these no longer style status UI.
const statusBlocked = Color(0xFFE5695E);
const statusUnknown = Color(0xFF6C7681);

// Dedicated colors for AgentMode, distinct from the status colors above so
// mode and agent-status never share meaning by accident.
const modeAcceptEdit = Color(0xFF9B7EC7);
const modePlan = Color(0xFF5FAF82);
// Matches Claude Code's own "auto mode on" mode-line color (SGR
// 38;2;255;193;7, captured live from a real session) rather than a color
// picked to sit apart from statusWorking.
const modeAuto = Color(0xFFFFC107);
const modeBypass = Color(0xFFE5695E);

/// Ink color tokens that don't map onto Material's [ColorScheme]: per-status
/// pill colors, agent brand colors, and a few bespoke surfaces.
/// Registered on both themes; read via [DroverColors.of].
@immutable
class DroverColors extends ThemeExtension<DroverColors> {
  const DroverColors({
    required this.blockedDot,
    required this.blockedPillBg,
    required this.blockedPillFg,
    required this.workingDot,
    required this.workingPillBg,
    required this.workingPillFg,
    required this.doneDot,
    required this.donePillBg,
    required this.donePillFg,
    required this.idleDot,
    required this.idlePillBg,
    required this.idlePillFg,
    required this.brandClaude,
    required this.brandCodex,
    required this.brandCopilot,
    required this.brandPi,
    required this.brandOmp,
    required this.brandFallback,
    required this.avatarFg,
    required this.userBubble,
    required this.toolSurface,
    required this.tertiaryText,
    required this.accentText,
  });

  // Status colors: dot / pill background / pill foreground per state.
  final Color blockedDot;
  final Color blockedPillBg;
  final Color blockedPillFg;
  final Color workingDot;
  final Color workingPillBg;
  final Color workingPillFg;
  final Color doneDot;
  final Color donePillBg;
  final Color donePillFg;
  final Color idleDot;
  final Color idlePillBg;
  final Color idlePillFg;

  // Agent brand colors (identical across themes) + neutral fallback.
  final Color brandClaude;
  final Color brandCodex;
  final Color brandCopilot;
  final Color brandPi;
  final Color brandOmp;
  final Color brandFallback;

  // Bespoke surfaces/text not covered by ColorScheme.
  final Color avatarFg;
  final Color userBubble;
  final Color toolSurface;
  final Color tertiaryText;

  /// Accent-coloured **text and icons** — a selected switcher label, the
  /// selection marks in the settings/host lists and the host switcher.
  ///
  /// Under the ink accent this equals [ColorScheme.onSurface], which is exactly
  /// right for a selection mark (nothing reads as "current" more clearly than
  /// full-strength ink) and useless for a text *action*, which has no hue left
  /// to distinguish it from body copy. The three text actions that used to lean
  /// on the hue carry an underline or a weight instead — see `demo_screen`,
  /// `settings_screen` and `structured_prompt_sheet`. The token is kept as its
  /// own name rather than folded into [ColorScheme.onSurface] so that the
  /// call sites still say *why* they are that colour.
  final Color accentText;

  /// Dot color for [status]; `unknown` reuses the idle triple.
  Color statusDot(AgentStatus status) => switch (status) {
    AgentStatus.blocked => blockedDot,
    AgentStatus.working => workingDot,
    AgentStatus.done => doneDot,
    AgentStatus.idle || AgentStatus.unknown => idleDot,
  };

  /// Pill background for [status]; `unknown` reuses the idle triple.
  Color statusPillBg(AgentStatus status) => switch (status) {
    AgentStatus.blocked => blockedPillBg,
    AgentStatus.working => workingPillBg,
    AgentStatus.done => donePillBg,
    AgentStatus.idle || AgentStatus.unknown => idlePillBg,
  };

  /// Pill foreground (text) for [status]; `unknown` reuses the idle triple.
  Color statusPillFg(AgentStatus status) => switch (status) {
    AgentStatus.blocked => blockedPillFg,
    AgentStatus.working => workingPillFg,
    AgentStatus.done => donePillFg,
    AgentStatus.idle || AgentStatus.unknown => idlePillFg,
  };

  /// Brand color for an agent [type] (e.g. `claude`/`codex`/`copilot`/`pi`/
  /// `omp`); unknown or null types fall back to a neutral tone.
  Color brandColor(String? type) => switch (type?.toLowerCase()) {
    'claude' => brandClaude,
    'codex' => brandCodex,
    'copilot' => brandCopilot,
    'pi' => brandPi,
    'omp' => brandOmp,
    _ => brandFallback,
  };

  /// Convenience accessor for the registered extension on [context]'s theme.
  static DroverColors of(BuildContext context) =>
      Theme.of(context).extension<DroverColors>()!;

  static const DroverColors dark = DroverColors(
    // Dot and pill text now share one hue per status. The label used to be a
    // lighter tint of the dot so it would lift off the warm ground; on ink it
    // no longer needs the lift, so it settles onto the dot's own value. idle
    // is the one pair that stays split — see its comment below.
    blockedDot: Color(0xFFE5695E),
    blockedPillBg: Color.fromRGBO(229, 105, 94, 0.12),
    blockedPillFg: Color(0xFFE5695E),
    workingDot: Color(0xFFD3A027),
    workingPillBg: Color.fromRGBO(211, 160, 39, 0.12),
    workingPillFg: Color(0xFFD3A027),
    doneDot: Color(0xFF5FAE74),
    // Green reads brighter than it measures, so its wash sits a step lighter.
    donePillBg: Color.fromRGBO(95, 174, 116, 0.10),
    donePillFg: Color(0xFF5FAE74),
    // idle (and the `unknown` status that reuses it) means "no particular
    // state", so unlike blocked/working/done it carries no hue of its own.
    // Its label stays lighter than its dot because it has no hue to lean on.
    idleDot: Color(0xFF7C7C84),
    idlePillBg: Color.fromRGBO(124, 124, 132, 0.12),
    idlePillFg: Color(0xFF908F96),
    brandClaude: Color(0xFFD9825F),
    brandCodex: Color(0xFF6FA287),
    brandCopilot: Color(0xFF8B9DC9),
    brandPi: Color(0xFFB98AC9),
    brandOmp: Color(0xFF55AAB9),
    // Same reasoning as idle: the fallback avatar for an unrecognised agent
    // type is the absence of a brand color.
    brandFallback: Color(0xFF908F96),
    // Sits on `brandColor(type)`, all of which are light enough to need the
    // page's own near-black rather than white.
    avatarFg: Color(0xFF17171A),
    // The ink accent has no hue to lend, so the bubble is separated from the
    // grey lozenges around it (tool chips, inline code, both [toolSurface]) by
    // lightness instead: a clear step above them rather than a different tint.
    userBubble: Color(0xFF33333A),
    toolSurface: Color(0xFF26262B),
    tertiaryText: Color(0xFF908F96),
    accentText: Color(0xFFEAE8EE),
  );

  static const DroverColors light = DroverColors(
    // The pill text is untouched — at chroma 62–115 it already carries the
    // whole signal. The pill *backgrounds* are washes pulled toward the neutral
    // axis at their own lightness, so the hue survives and the text/background
    // contrast is unchanged to two decimals; on the warm ground they used to
    // sit on they read as loose yellow and pink cards. The dots are the ink
    // pass's one change here: saturated further so a 5×5 square LED still
    // registers as a colour at that size.
    blockedDot: Color(0xFFC73E3E),
    blockedPillBg: Color(0xFFF1E6E4),
    blockedPillFg: Color(0xFFA94B36),
    workingDot: Color(0xFFB8860B),
    workingPillBg: Color(0xFFF0EBE2),
    workingPillFg: Color(0xFF8F6A1D),
    doneDot: Color(0xFF2D9F52),
    donePillBg: Color(0xFFE5EEE7),
    donePillFg: Color(0xFF3E7C51),
    // idle (and the `unknown` status that reuses it) means "no particular
    // state", so unlike blocked/working/done it carries no hue of its own.
    idleDot: Color(0xFF8B8B90),
    idlePillBg: Color(0xFFE9E9ED),
    idlePillFg: Color(0xFF76767B),
    brandClaude: Color(0xFFD9825F),
    brandCodex: Color(0xFF6FA287),
    brandCopilot: Color(0xFF8B9DC9),
    brandPi: Color(0xFFB98AC9),
    brandOmp: Color(0xFF55AAB9),
    // Same reasoning: the fallback avatar for an unrecognised agent type is
    // the absence of a brand color.
    brandFallback: Color(0xFF7E7E83),
    // Sits on `brandColor(type)`, and for an unrecognised type that is the
    // cool grey [brandFallback] rather than an accent — so it is pinned to
    // white here rather than tracking any one of the brand hues.
    avatarFg: Color(0xFFFFFFFF),
    // As in dark: no accent hue to borrow, so the bubble is set apart from
    // [toolSurface] and the inline-code lozenges by lightness, sitting a step
    // below them on the descending ladder. 1.22:1 against `toolSurface` —
    // matching the 1.20:1 the dark bubble keeps — because the first value
    // tried here (#E4E4EA) came out at 1.08:1 and reproduced exactly the
    // grey-on-grey collision this token has always been written to avoid.
    userBubble: Color(0xFFD8D8DE),
    toolSurface: Color(0xFFEDEDF1),
    // A shade darker than the axis shift alone would give, to make up the
    // contrast the deeper ground (247 → 243) would otherwise have cost it.
    tertiaryText: Color(0xFF86868B),
    accentText: Color(0xFF1F1F22),
  );

  @override
  DroverColors copyWith({
    Color? blockedDot,
    Color? blockedPillBg,
    Color? blockedPillFg,
    Color? workingDot,
    Color? workingPillBg,
    Color? workingPillFg,
    Color? doneDot,
    Color? donePillBg,
    Color? donePillFg,
    Color? idleDot,
    Color? idlePillBg,
    Color? idlePillFg,
    Color? brandClaude,
    Color? brandCodex,
    Color? brandCopilot,
    Color? brandPi,
    Color? brandOmp,
    Color? brandFallback,
    Color? avatarFg,
    Color? userBubble,
    Color? toolSurface,
    Color? tertiaryText,
    Color? accentText,
  }) => DroverColors(
    blockedDot: blockedDot ?? this.blockedDot,
    blockedPillBg: blockedPillBg ?? this.blockedPillBg,
    blockedPillFg: blockedPillFg ?? this.blockedPillFg,
    workingDot: workingDot ?? this.workingDot,
    workingPillBg: workingPillBg ?? this.workingPillBg,
    workingPillFg: workingPillFg ?? this.workingPillFg,
    doneDot: doneDot ?? this.doneDot,
    donePillBg: donePillBg ?? this.donePillBg,
    donePillFg: donePillFg ?? this.donePillFg,
    idleDot: idleDot ?? this.idleDot,
    idlePillBg: idlePillBg ?? this.idlePillBg,
    idlePillFg: idlePillFg ?? this.idlePillFg,
    brandClaude: brandClaude ?? this.brandClaude,
    brandCodex: brandCodex ?? this.brandCodex,
    brandCopilot: brandCopilot ?? this.brandCopilot,
    brandPi: brandPi ?? this.brandPi,
    brandOmp: brandOmp ?? this.brandOmp,
    brandFallback: brandFallback ?? this.brandFallback,
    avatarFg: avatarFg ?? this.avatarFg,
    userBubble: userBubble ?? this.userBubble,
    toolSurface: toolSurface ?? this.toolSurface,
    tertiaryText: tertiaryText ?? this.tertiaryText,
    accentText: accentText ?? this.accentText,
  );

  @override
  DroverColors lerp(covariant DroverColors? other, double t) {
    if (other == null) return this;
    return DroverColors(
      blockedDot: Color.lerp(blockedDot, other.blockedDot, t)!,
      blockedPillBg: Color.lerp(blockedPillBg, other.blockedPillBg, t)!,
      blockedPillFg: Color.lerp(blockedPillFg, other.blockedPillFg, t)!,
      workingDot: Color.lerp(workingDot, other.workingDot, t)!,
      workingPillBg: Color.lerp(workingPillBg, other.workingPillBg, t)!,
      workingPillFg: Color.lerp(workingPillFg, other.workingPillFg, t)!,
      doneDot: Color.lerp(doneDot, other.doneDot, t)!,
      donePillBg: Color.lerp(donePillBg, other.donePillBg, t)!,
      donePillFg: Color.lerp(donePillFg, other.donePillFg, t)!,
      idleDot: Color.lerp(idleDot, other.idleDot, t)!,
      idlePillBg: Color.lerp(idlePillBg, other.idlePillBg, t)!,
      idlePillFg: Color.lerp(idlePillFg, other.idlePillFg, t)!,
      brandClaude: Color.lerp(brandClaude, other.brandClaude, t)!,
      brandCodex: Color.lerp(brandCodex, other.brandCodex, t)!,
      brandCopilot: Color.lerp(brandCopilot, other.brandCopilot, t)!,
      brandPi: Color.lerp(brandPi, other.brandPi, t)!,
      brandOmp: Color.lerp(brandOmp, other.brandOmp, t)!,
      brandFallback: Color.lerp(brandFallback, other.brandFallback, t)!,
      avatarFg: Color.lerp(avatarFg, other.avatarFg, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      toolSurface: Color.lerp(toolSurface, other.toolSurface, t)!,
      tertiaryText: Color.lerp(tertiaryText, other.tertiaryText, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
    );
  }
}
