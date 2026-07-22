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
  });
  final String label;
  final String bin;
  final String kind;
}

const kAgentPresets = <AgentPreset>[
  AgentPreset(label: 'Claude Code', bin: 'claude', kind: 'claude'),
  AgentPreset(label: 'Codex', bin: 'codex', kind: 'codex'),
  AgentPreset(label: 'Copilot CLI', bin: 'copilot', kind: 'copilot'),
];
