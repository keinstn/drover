/// A launchable agent: [label] is shown in the UI, [bin] is the binary probed
/// on the host PATH to decide availability, and [kind] is passed to
/// `herdr agent start`. Herdr can only surface an agent in its list if it has a
/// detection integration for it, so this list mirrors herdr's supported agents
/// (`herdr integration`). Extend as needed; keep `bin` = the launch binary.
class AgentPreset {
  const AgentPreset({
    required this.label,
    required this.bin,
    required this.kind,
    String? shortLabel,
  }) : shortLabel = shortLabel ?? label;
  final String label;

  /// Fits the launch button, where [label] would be cut off.
  final String shortLabel;
  final String bin;
  final String kind;
}

const kAgentPresets = <AgentPreset>[
  AgentPreset(
    label: 'Claude Code',
    shortLabel: 'Claude',
    bin: 'claude',
    kind: 'claude',
  ),
  AgentPreset(label: 'Codex', bin: 'codex', kind: 'codex'),
  AgentPreset(
    label: 'Copilot CLI',
    shortLabel: 'Copilot',
    bin: 'copilot',
    kind: 'copilot',
  ),
  AgentPreset(label: 'pi', bin: 'pi', kind: 'pi'),
  AgentPreset(label: 'omp', bin: 'omp', kind: 'omp'),
];
