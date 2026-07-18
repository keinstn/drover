import 'agent_preset.dart';

/// Claude Code's `--permission-mode` launch flag. Only a curated subset of
/// Claude's actual CLI values is exposed here (see each case) to keep the
/// launch UI simple.
enum ClaudePermissionMode {
  defaultMode(label: 'Default', flag: null),
  plan(label: 'Plan', flag: 'plan'),
  acceptEdits(label: 'Accept edits', flag: 'acceptEdits'),
  bypassPermissions(label: 'Bypass permissions', flag: 'bypassPermissions');

  const ClaudePermissionMode({required this.label, required this.flag});

  final String label;
  final String? flag;
}

/// Builds the argv to launch [preset] with, appending Claude's
/// `--permission-mode` flag when [preset] is Claude and [mode] carries one.
/// Non-Claude presets and [ClaudePermissionMode.defaultMode] pass [preset]'s
/// argv through unchanged.
List<String> launchArgv(AgentPreset preset, ClaudePermissionMode mode) {
  if (preset.bin != 'claude' || mode.flag == null) {
    return preset.argv;
  }
  return [...preset.argv, '--permission-mode', mode.flag!];
}
