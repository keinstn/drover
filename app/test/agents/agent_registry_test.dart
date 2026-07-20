import 'package:drover/src/agents/agent_adapter.dart';
import 'package:drover/src/agents/agent_registry.dart';
import 'package:drover/src/agents/claude/claude_adapter.dart';
import 'package:drover/src/agents/copilot/copilot_adapter.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCommandRunner extends CommandRunner {
  @override
  Future<CommandResult> run(String command) =>
      Future.value(const CommandResult(exitCode: 0, stdout: '', stderr: ''));

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

AgentInfo _agent(String agent, {AgentSession? agentSession}) => AgentInfo(
  paneId: 'w:p',
  workspaceId: 'w',
  tabId: 'w:t',
  agent: agent,
  status: AgentStatus.idle,
  cwd: '/tmp/proj',
  focused: false,
  agentSession: agentSession,
);

void main() {
  group('resolveAgentAdapter', () {
    test('resolves a Claude agent to ClaudeAgentAdapter', () {
      final adapter = resolveAgentAdapter(_agent('claude'));

      expect(adapter, isA<ClaudeAgentAdapter>());
    });

    test('resolves a Copilot agent to CopilotAgentAdapter', () {
      final adapter = resolveAgentAdapter(_agent('copilot'));

      expect(adapter, isA<CopilotAgentAdapter>());
    });

    test('returns null for an unrecognized agent', () {
      expect(resolveAgentAdapter(_agent('codex')), isNull);
    });
  });

  group('ClaudeAgentAdapter capabilities', () {
    const adapter = ClaudeAgentAdapter();

    test('supports only the claude agent', () {
      expect(adapter.supports(_agent('claude')), isTrue);
      expect(adapter.supports(_agent('codex')), isFalse);
    });

    test('exposes mode, structured-prompt, and image capabilities', () {
      expect(adapter.mode, isNotNull);
      expect(adapter.structuredPrompt, isNotNull);
      expect(adapter.images, isNotNull);
    });

    test(
      'createNativeHistory returns null without a matching agent session',
      () {
        final loader = adapter.createNativeHistory(
          _FakeCommandRunner(),
          _agent('claude'),
        );

        expect(loader, isNull);
      },
    );

    test('createNativeHistory returns a loader for a valid Claude session', () {
      final loader = adapter.createNativeHistory(
        _FakeCommandRunner(),
        _agent(
          'claude',
          agentSession: const AgentSession(
            source: 'claude',
            agent: 'claude',
            kind: 'id',
            value: 'c7c50b87-4d4c-4a92-9396-2cfa4158612d',
          ),
        ),
      );

      expect(loader, isNotNull);
    });
  });

  group('CopilotAgentAdapter capabilities', () {
    const adapter = CopilotAgentAdapter();

    test('supports only the copilot agent', () {
      expect(adapter.supports(_agent('copilot')), isTrue);
      expect(adapter.supports(_agent('codex')), isFalse);
    });

    test('exposes mode only', () {
      expect(adapter.mode, isNotNull);
    });

    test('leaves images, structured-prompt, and native history null for this '
        'unit', () {
      expect(adapter.images, isNull);
      expect(adapter.structuredPrompt, isNull);
      expect(
        adapter.createNativeHistory(_FakeCommandRunner(), _agent('copilot')),
        isNull,
      );
    });
  });

  group('unsupported agent fallback', () {
    test('has no adapter, so every optional capability is absent', () {
      final agent = _agent('codex');
      final adapter = resolveAgentAdapter(agent);

      expect(adapter, isNull);
      // AgentScreen resolves each capability off the (possibly null) adapter
      // with `?.`, so a null adapter means every capability getter below is
      // simply unavailable — the generic pane-text/numbered-prompt fallback
      // takes over instead of throwing.
      expect(adapter?.mode, isNull);
      expect(adapter?.structuredPrompt, isNull);
      expect(adapter?.images, isNull);
      expect(adapter?.createNativeHistory(_FakeCommandRunner(), agent), isNull);
    });
  });

  group('AgentAdapter default capabilities', () {
    test('a bare adapter leaves every optional capability null', () {
      final adapter = _NoOpAdapter();

      expect(adapter.mode, isNull);
      expect(adapter.structuredPrompt, isNull);
      expect(adapter.images, isNull);
      expect(
        adapter.createNativeHistory(_FakeCommandRunner(), _agent('mystery')),
        isNull,
      );
    });
  });
}

/// A minimal [AgentAdapter] that supports one made-up agent and overrides no
/// capability, exercising [AgentAdapter]'s "everything optional" defaults.
class _NoOpAdapter extends AgentAdapter {
  @override
  bool supports(AgentInfo agent) => agent.agent == 'mystery';
}
