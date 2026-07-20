/// A launchable agent: [label] is shown in the UI, [bin] is the binary probed
/// on the host PATH to decide availability, and [argv] is the command run by
/// `herdr agent start`. Herdr can only surface an agent in its list if it has a
/// detection integration for it, so this list mirrors herdr's supported agents
/// (`herdr integration`). Extend as needed; keep `bin` = the launch binary.
class AgentPreset {
  const AgentPreset({
    required this.label,
    required this.bin,
    required this.argv,
  });
  final String label;
  final String bin;
  final List<String> argv;
}

const kAgentPresets = <AgentPreset>[
  AgentPreset(label: 'Claude Code', bin: 'claude', argv: ['claude']),
  AgentPreset(label: 'Codex', bin: 'codex', argv: ['codex']),
  AgentPreset(label: 'Copilot CLI', bin: 'copilot', argv: ['copilot']),
  AgentPreset(label: 'pi', bin: 'pi', argv: ['pi']),
  AgentPreset(label: 'oh-my-pi', bin: 'omp', argv: ['omp']),
];
