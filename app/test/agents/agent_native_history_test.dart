import 'package:drover/src/agents/agent_adapter.dart';
import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/agent_native_history.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/transcript/native_transcript.dart';
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

/// A [NativeTranscriptAdapter] returning a fixed [NativeTranscript]
/// regardless of session state — standing in for a future adapter that
/// doesn't require an `agent_session`.
class _FixedHistoryAdapter implements NativeTranscriptAdapter {
  const _FixedHistoryAdapter(this.transcript);

  final NativeTranscript transcript;

  @override
  Future<NativeTranscript?> load(AgentInfo agent) async => transcript;
}

/// An [AgentAdapter] that supports every agent and hands back [history] (or
/// null), counting how many times [createNativeHistory] is invoked so tests
/// can assert on (re-)resolution.
class _StubAdapter extends AgentAdapter {
  _StubAdapter(this.history);

  final NativeTranscriptAdapter? history;
  var createCalls = 0;

  @override
  bool supports(AgentInfo agent) => true;

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    AgentInfo agent,
  ) {
    createCalls++;
    return history;
  }
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
  group('NativeTranscriptHistory', () {
    test(
      'resolves to null (the pane-text fallback) for an unsupported agent',
      () async {
        final history = NativeTranscriptHistory(_FakeCommandRunner());

        final transcript = await history.load(_agent('codex'));

        expect(transcript, isNull);
      },
    );

    test(
      'resolves to null for a Claude agent with no matching session yet',
      () async {
        final history = NativeTranscriptHistory(_FakeCommandRunner());

        final transcript = await history.load(_agent('claude'));

        expect(transcript, isNull);
      },
    );

    test(
      'consults the registry on the very first load even with no session',
      () async {
        // A hypothetical adapter that doesn't need `agent_session` at all —
        // its `createNativeHistory` must still be invoked on the first load,
        // even though `sessionIdentityFor` resolves to null.
        const fixed = NativeTranscript([
          TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'hi'),
        ]);
        final adapter = _StubAdapter(const _FixedHistoryAdapter(fixed));
        final history = NativeTranscriptHistory(
          _FakeCommandRunner(),
          resolveAdapter: (agent) => adapter,
        );

        final transcript = await history.load(_agent('no-session-agent'));

        expect(adapter.createCalls, 1);
        expect(transcript, same(fixed));
      },
    );

    test(
      're-resolves the adapter when switching between agents with no '
      'session, rather than reusing the first agent kind\'s cached adapter',
      () async {
        const transcriptA = NativeTranscript([
          TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'A'),
        ]);
        const transcriptB = NativeTranscript([
          TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'B'),
        ]);
        final resolvedFor = <String>[];
        AgentAdapter? resolve(AgentInfo agent) {
          resolvedFor.add(agent.agent);
          return switch (agent.agent) {
            'alpha' => _StubAdapter(const _FixedHistoryAdapter(transcriptA)),
            'beta' => _StubAdapter(const _FixedHistoryAdapter(transcriptB)),
            _ => null,
          };
        }

        final history = NativeTranscriptHistory(
          _FakeCommandRunner(),
          resolveAdapter: resolve,
        );

        // Neither 'alpha' nor 'beta' has an agent_session, so their
        // session-only identity is null for both — the registry must still
        // be re-consulted when the agent kind itself changes.
        final first = await history.load(_agent('alpha'));
        final second = await history.load(_agent('beta'));

        expect(resolvedFor, ['alpha', 'beta']);
        expect(first, same(transcriptA));
        expect(second, same(transcriptB));
      },
    );

    test('reuses the same adapter across polls for one session (no '
        're-resolution)', () async {
      var createCalls = 0;
      final agent = _agent(
        'claude',
        agentSession: const AgentSession(
          source: 'claude',
          agent: 'claude',
          kind: 'id',
          value: 'abc123',
        ),
      );
      final history = NativeTranscriptHistory(
        _FakeCommandRunner(),
        resolveAdapter: (agent) {
          createCalls++;
          return _StubAdapter(const _FixedHistoryAdapter(NativeTranscript([])));
        },
      );

      await history.load(agent);
      await history.load(agent);
      await history.load(agent);

      expect(createCalls, 1);
    });
  });

  group('NativeTranscriptHistory.sessionIdentityFor', () {
    test('is null without an agent session', () {
      expect(
        NativeTranscriptHistory.sessionIdentityFor(_agent('claude')),
        isNull,
      );
    });

    test('combines agent, kind, and value when a session is present', () {
      final agent = _agent(
        'claude',
        agentSession: const AgentSession(
          source: 'claude',
          agent: 'claude',
          kind: 'id',
          value: 'abc123',
        ),
      );

      expect(
        NativeTranscriptHistory.sessionIdentityFor(agent),
        'claude:id:abc123',
      );
    });
  });
}
