import 'package:flutter/material.dart';

/// Ink — drover's dark-only, near-neutral color scheme. The primary action
/// uses a near-white fill instead of a colored accent; the only chroma in the
/// UI is the status colors below.
final ThemeData droverTheme = ThemeData(
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF6B7686),
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF131519),
        surfaceContainerLowest: const Color(0xFF0E1013),
        surfaceContainerLow: const Color(0xFF17191E),
        surfaceContainer: const Color(0xFF1A1D22),
        surfaceContainerHigh: const Color(0xFF22262C),
        surfaceContainerHighest: const Color(0xFF2A2F36),
        onSurface: const Color(0xFFE7E9ED),
        onSurfaceVariant: const Color(0xFF969CA6),
        outline: const Color(0xFF333840),
        outlineVariant: const Color(0xFF24282F),
        primary: const Color(0xFFD6DAE0),
        onPrimary: const Color(0xFF15181C),
        surfaceTint: const Color(0xFFD6DAE0),
        error: const Color(0xFFE5695E),
        onError: const Color(0xFF2A0D08),
      ),
  useMaterial3: true,
);

// Semantic status/mode colors, centralized here so every screen agrees on
// what "blocked", "working", etc. look like. Swap these values here when a
// light theme is added.
const statusIdle = Color(0xFF7E8894);
const statusWorking = Color(0xFFE0A93F);
const statusBlocked = Color(0xFFE5695E);
const statusDone = Color(0xFF63C08C);
const statusUnknown = Color(0xFF6C7681);

/// Used for [AgentMode.plan] only — distinct from the status colors above.
const modePlan = Color(0xFF6FA8D8);
