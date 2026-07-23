import 'package:flutter/material.dart';

import 'models/agent_info.dart';

/// System rounded-gothic fallback for the warm redesign. The spec calls for
/// M PLUS Rounded 1c; rather than add a `google_fonts` dependency we lean on
/// the platform's Hiragino Maru Gothic ProN, which the README sanctions as the
/// fallback. Monospace usages (code/args/PEM) opt out locally and are untouched.
const _roundedGothic = 'Hiragino Maru Gothic ProN';

/// Warm dark theme. Surfaces/text come from the README's サーフェス token table;
/// the semantic status/brand colors live in [DroverColors] below.
final ThemeData droverDarkTheme = _buildTheme(
  brightness: Brightness.dark,
  scheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFE0956B),
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF191511),
        surfaceContainerLowest: const Color(0xFF15120E),
        surfaceContainerLow: const Color(0xFF1D1812),
        surfaceContainer: const Color(0xFF221D17),
        surfaceContainerHigh: const Color(0xFF241E17),
        onSurface: const Color(0xFFF0E9DF),
        onSurfaceVariant: const Color(0xFFA69B8C),
        outline: const Color(0xFF3B332A),
        outlineVariant: const Color(0xFF2A241C),
        primary: const Color(0xFFE0956B),
        onPrimary: const Color(0xFF241409),
        surfaceTint: const Color(0xFFE0956B),
        error: const Color(0xFFE86A55),
      ),
  colors: DroverColors.dark,
);

/// Warm light theme, same token structure as [droverDarkTheme].
final ThemeData droverLightTheme = _buildTheme(
  brightness: Brightness.light,
  scheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFC2704E),
        brightness: Brightness.light,
      ).copyWith(
        surface: const Color(0xFFF6F1E8),
        surfaceContainerLowest: const Color(0xFFFBF7EF),
        surfaceContainerLow: const Color(0xFFFBF6EC),
        surfaceContainer: const Color(0xFFFFFCF6),
        surfaceContainerHigh: const Color(0xFFFFFCF6),
        onSurface: const Color(0xFF33291E),
        onSurfaceVariant: const Color(0xFF8A7E6E),
        outline: const Color(0xFFEAE1D1),
        outlineVariant: const Color(0xFFE7DECF),
        primary: const Color(0xFFC2704E),
        onPrimary: const Color(0xFFFFF6EE),
        surfaceTint: const Color(0xFFC2704E),
        error: const Color(0xFFC75B44),
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

/// Warm-redesign color tokens that don't map onto Material's [ColorScheme]:
/// per-status pill colors, agent brand colors, and a few bespoke surfaces.
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
    blockedDot: Color(0xFFE86A55),
    blockedPillBg: Color.fromRGBO(232, 106, 85, 0.16),
    blockedPillFg: Color(0xFFF09480),
    workingDot: Color(0xFFE0A93F),
    workingPillBg: Color.fromRGBO(224, 169, 63, 0.14),
    workingPillFg: Color(0xFFE6B863),
    doneDot: Color(0xFF7CBE8C),
    donePillBg: Color.fromRGBO(124, 190, 140, 0.14),
    donePillFg: Color(0xFF95CFA4),
    idleDot: Color(0xFF8D8478),
    idlePillBg: Color.fromRGBO(160, 150, 136, 0.12),
    idlePillFg: Color(0xFFA69B8C),
    brandClaude: Color(0xFFD9825F),
    brandCodex: Color(0xFF6FA287),
    brandCopilot: Color(0xFF8B9DC9),
    brandFallback: Color(0xFFA69B8C),
    avatarFg: Color(0xFF1D150E),
    userBubble: Color(0xFF3A2E22),
    toolSurface: Color(0xFF221D17),
    tertiaryText: Color(0xFF8C8172),
  );

  static const DroverColors light = DroverColors(
    blockedDot: Color(0xFFC75B44),
    blockedPillBg: Color(0xFFF9E4DE),
    blockedPillFg: Color(0xFFA94B36),
    workingDot: Color(0xFFB8862F),
    workingPillBg: Color(0xFFF6EBD2),
    workingPillFg: Color(0xFF8F6A1D),
    doneDot: Color(0xFF4E9465),
    donePillBg: Color(0xFFE2EFE3),
    donePillFg: Color(0xFF3E7C51),
    idleDot: Color(0xFF9A8F7E),
    idlePillBg: Color(0xFFEFE9DD),
    idlePillFg: Color(0xFF83786A),
    brandClaude: Color(0xFFD9825F),
    brandCodex: Color(0xFF6FA287),
    brandCopilot: Color(0xFF8B9DC9),
    brandFallback: Color(0xFF8A7E6E),
    avatarFg: Color(0xFFFFF9F0),
    userBubble: Color(0xFFF0E2D0),
    toolSurface: Color(0xFFF1EBDF),
    tertiaryText: Color(0xFF9A8F7E),
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
