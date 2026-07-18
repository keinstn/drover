import 'package:drover/src/models/agent_preset.dart';
import 'package:drover/src/models/claude_permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('launchArgv', () {
    const claude = AgentPreset(
      label: 'Claude Code',
      bin: 'claude',
      argv: ['claude'],
    );
    const codex = AgentPreset(label: 'Codex', bin: 'codex', argv: ['codex']);

    test('appends --permission-mode for a Claude preset with a mode', () {
      expect(launchArgv(claude, ClaudePermissionMode.plan), [
        'claude',
        '--permission-mode',
        'plan',
      ]);
    });

    test('leaves argv unchanged for the default mode', () {
      expect(launchArgv(claude, ClaudePermissionMode.defaultMode), ['claude']);
    });

    test('leaves argv unchanged for a non-Claude preset', () {
      expect(launchArgv(codex, ClaudePermissionMode.plan), ['codex']);
    });
  });
}
