import 'package:flutter/material.dart';

import 'models/agent_info.dart';

/// System rounded-gothic fallback for the warm redesign. The spec calls for
/// M PLUS Rounded 1c; rather than add a `google_fonts` dependency we lean on
/// the platform's Hiragino Maru Gothic ProN, which the README sanctions as the
/// fallback. Monospace usages (code/args/PEM) opt out locally and are untouched.
const _roundedGothic = 'Hiragino Maru Gothic ProN';

/// Green-accent dark theme ("border collie × grassland"): near-neutral
/// black surfaces, grassland-green reserved for tappable elements. Surfaces/
/// text come from the README's サーフェス token table; the semantic
/// status/brand colors live in [DroverColors] below.
final ThemeData droverDarkTheme = _buildTheme(
  brightness: Brightness.dark,
  scheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF74B25C),
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF151815),
        surfaceContainerLowest: const Color(0xFF131613),
        surfaceContainerLow: const Color(0xFF1A1E19),
        surfaceContainer: const Color(0xFF1D211C),
        surfaceContainerHigh: const Color(0xFF1E231E),
        onSurface: const Color(0xFFEDF0E9),
        onSurfaceVariant: const Color(0xFF98A292),
        outline: const Color(0xFF2E342D),
        outlineVariant: const Color(0xFF262B25),
        primary: const Color(0xFF74B25C),
        onPrimary: const Color(0xFF0E1A09),
        surfaceTint: const Color(0xFF74B25C),
        error: const Color(0xFFE8705A),
      ),
  colors: DroverColors.dark,
);

/// Green-accent light theme, same token structure as [droverDarkTheme].
final ThemeData droverLightTheme = _buildTheme(
  brightness: Brightness.light,
  scheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF3F7D39),
        brightness: Brightness.light,
      ).copyWith(
        surface: const Color(0xFFF5F3EB),
        surfaceContainerLowest: const Color(0xFFFAF8F1),
        surfaceContainerLow: const Color(0xFFFAF8F1),
        surfaceContainer: const Color(0xFFFDFCF6),
        surfaceContainerHigh: const Color(0xFFFDFCF6),
        onSurface: const Color(0xFF1E221C),
        onSurfaceVariant: const Color(0xFF6B7268),
        outline: const Color(0xFFE4E2D6),
        outlineVariant: const Color(0xFFE4E2D6),
        primary: const Color(0xFF3F7D39),
        onPrimary: const Color(0xFFF4F9F0),
        surfaceTint: const Color(0xFF3F7D39),
        error: const Color(0xFFC25742),
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
  fontFamily: _roundedGothic,
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

/// Green-accent theme color tokens that don't map onto Material's
/// [ColorScheme]: per-status pill colors, agent brand colors, and a few
/// bespoke surfaces. Registered on both themes; read via [DroverColors.of].
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
    required this.brandFallback,
    required this.avatarFg,
    required this.userBubble,
    required this.toolSurface,
    required this.tertiaryText,
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
  final Color brandFallback;

  // Bespoke surfaces/text not covered by ColorScheme.
  final Color avatarFg;
  final Color userBubble;
  final Color toolSurface;
  final Color tertiaryText;

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

  /// Brand color for an agent [type] (e.g. `claude`/`codex`/`copilot`);
  /// unknown or null types fall back to a neutral tone.
  Color brandColor(String? type) => switch (type?.toLowerCase()) {
    'claude' => brandClaude,
    'codex' => brandCodex,
    'copilot' => brandCopilot,
    _ => brandFallback,
  };

  /// Convenience accessor for the registered extension on [context]'s theme.
  static DroverColors of(BuildContext context) =>
      Theme.of(context).extension<DroverColors>()!;

  static const DroverColors dark = DroverColors(
    blockedDot: Color(0xFFE8705A),
    blockedPillBg: Color.fromRGBO(232, 112, 90, 0.16),
    blockedPillFg: Color(0xFFF0937E),
    workingDot: Color(0xFFE7B444),
    workingPillBg: Color.fromRGBO(231, 180, 68, 0.14),
    workingPillFg: Color(0xFFEFC873),
    doneDot: Color(0xFF6FB6DE),
    donePillBg: Color.fromRGBO(111, 182, 222, 0.14),
    donePillFg: Color(0xFF8CC8E8),
    idleDot: Color(0xFF8B948A),
    idlePillBg: Color.fromRGBO(150, 160, 148, 0.12),
    idlePillFg: Color(0xFF98A292),
    brandClaude: Color(0xFFC9743F),
    brandCodex: Color(0xFF4E93B0),
    brandCopilot: Color(0xFF9A8BC4),
    brandFallback: Color(0xFF98A292),
    avatarFg: Color(0xFF14170F),
    userBubble: Color(0xFF2C332B),
    toolSurface: Color(0xFF1D211C),
    tertiaryText: Color(0xFF8A9387),
  );

  static const DroverColors light = DroverColors(
    blockedDot: Color(0xFFC25742),
    blockedPillBg: Color(0xFFF8E3DD),
    blockedPillFg: Color(0xFFA64834),
    workingDot: Color(0xFFB0821F),
    workingPillBg: Color(0xFFF5EBD0),
    workingPillFg: Color(0xFF8A6618),
    doneDot: Color(0xFF3D7EA6),
    donePillBg: Color(0xFFDFEDF6),
    donePillFg: Color(0xFF2F6787),
    idleDot: Color(0xFF8A9086),
    idlePillBg: Color(0xFFE9EBE4),
    idlePillFg: Color(0xFF6B736A),
    brandClaude: Color(0xFFC9743F),
    brandCodex: Color(0xFF4E93B0),
    brandCopilot: Color(0xFF9A8BC4),
    brandFallback: Color(0xFF6B7268),
    avatarFg: Color(0xFFFFF9F0),
    userBubble: Color(0xFFE6E7DD),
    toolSurface: Color(0xFFEFEFE4),
    tertiaryText: Color(0xFF8A9086),
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
    Color? brandFallback,
    Color? avatarFg,
    Color? userBubble,
    Color? toolSurface,
    Color? tertiaryText,
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
    brandFallback: brandFallback ?? this.brandFallback,
    avatarFg: avatarFg ?? this.avatarFg,
    userBubble: userBubble ?? this.userBubble,
    toolSurface: toolSurface ?? this.toolSurface,
    tertiaryText: tertiaryText ?? this.tertiaryText,
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
      brandFallback: Color.lerp(brandFallback, other.brandFallback, t)!,
      avatarFg: Color.lerp(avatarFg, other.avatarFg, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      toolSurface: Color.lerp(toolSurface, other.toolSurface, t)!,
      tertiaryText: Color.lerp(tertiaryText, other.tertiaryText, t)!,
    );
  }
}
