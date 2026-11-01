import 'package:flutter/material.dart';

import '../app_theme.dart';

/// A rounded-rect avatar for an agent: the agent's mark (the same ones the
/// herdr desktop app uses) centred on a neutral tile, or a bot glyph for an
/// unrecognised type. Gives each agent a recognizable "face" in lists and the
/// switcher bar. State is shown beside it, not on it (`AgentStatusIndicator`).
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.agent,
    this.size = 40,
    this.radius = droverRadiusMedium,
  });

  /// Agent type (e.g. `claude`, `codex`, `copilot`, `pi`); null when unknown.
  final String? agent;
  final double size;
  final double radius;

  /// Agents with a bundled mark under `assets/agents/`. Colour marks are drawn
  /// as-is; monochrome ones are white masks tinted to the theme's ink.
  static const _colorMarks = {'claude', 'codex'};
  static const _monoMarks = {'copilot', 'pi'};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = agent?.toLowerCase();
    final markSize = size * 0.6;
    final mark = _colorMarks.contains(type) || _monoMarks.contains(type)
        ? Image.asset(
            'assets/agents/$type.png',
            width: markSize,
            height: markSize,
            fit: BoxFit.contain,
            color: _monoMarks.contains(type) ? scheme.onSurface : null,
            colorBlendMode: BlendMode.srcIn,
            semanticLabel: agent,
          )
        : Icon(
            Icons.smart_toy_outlined,
            size: markSize,
            color: scheme.onSurfaceVariant,
            semanticLabel: agent,
          );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: mark,
    );
  }
}
