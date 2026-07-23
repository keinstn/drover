import 'package:flutter/material.dart';

import '../app_theme.dart';

/// A rounded-rect avatar for an agent, filled with the agent type's brand
/// color and stamped with a single initial (claude→C, codex→X, copilot→P;
/// otherwise the first letter of the type, or `?` when unknown). Gives each
/// agent a recognizable "face" in lists and the switcher bar.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.agent,
    this.size = 40,
    this.radius = 14,
  });

  /// Agent type (e.g. `claude`, `codex`, `copilot`); null when unknown.
  final String? agent;
  final double size;
  final double radius;

  String get _initial {
    switch (agent?.toLowerCase()) {
      case 'claude':
        return 'C';
      case 'codex':
        return 'X';
      case 'copilot':
        return 'P';
    }
    final type = agent?.trim();
    if (type == null || type.isEmpty) return '?';
    return type[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.brandColor(agent),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        _initial,
        style: TextStyle(
          color: colors.avatarFg,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}
