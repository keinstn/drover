import 'dart:async';
import 'dart:convert';

import 'package:drover/src/agents/agent_adapter.dart';
import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/agent_native_history.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/host_platform.dart';
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

  @override
  bool get hasOlderHistory => false;

  @override
  Future<NativeTranscript?> loadOlder(AgentInfo agent) => Future.value(null);
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
    HostPlatform platform,
    AgentInfo agent,
  ) {
    createCalls++;
    return history;
  }
}

/// Records entry and exit from each operation and can pause [load], letting
/// tests observe whether the shared history serializes adapter mutations.
class _GatedHistoryAdapter implements NativeTranscriptAdapter {
  _GatedHistoryAdapter({this.loadGate});

  Completer<void>? loadGate;
  final loadStarted = Completer<void>();
  final events = <String>[];
  var loadCalls = 0;
  var loadOlderCalls = 0;
  var concurrentAccessDetected = false;
  var _busy = false;

  @override
  bool get hasOlderHistory => true;

  @override
  Future<NativeTranscript?> load(AgentInfo agent) => _guarded(() async {
    loadCalls++;
    events.add('load-start');
    final gate = loadGate;
    if (gate != null) {
      if (!loadStarted.isCompleted) loadStarted.complete();
      await gate.future;
    }
    events.add('load-end');
    return const NativeTranscript([]);
  });

  @override
  Future<NativeTranscript?> loadOlder(AgentInfo agent) => _guarded(() async {
    loadOlderCalls++;
    events.add('loadOlder');
    return const NativeTranscript([]);
  });

  Future<NativeTranscript?> _guarded(
    Future<NativeTranscript?> Function() action,
  ) async {
    if (_busy) concurrentAccessDetected = true;
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }
}

/// A small real [JsonlTranscriptWindow] behind a gated range reader. Two
/// concurrent initial loads would both read offset zero and advance the
/// window's internal read end twice, so this catches the concrete duplicate
/// read/read-end-overrun failure that owner-level serialization prevents.
class _GatedWindowHistoryAdapter implements NativeTranscriptAdapter {
  _GatedWindowHistoryAdapter(this.contents);

  String contents;
  final window = JsonlTranscriptWindow(windowBytes: 32);
  final firstReadStarted = Completer<void>();
  final releaseFirstRead = Completer<void>();
  final readOffsets = <int>[];
  final readLengths = <int?>[];
  var _blockFirstRead = true;
  var readEndOverrun = false;

  @override
  bool get hasOlderHistory => window.hasOlder;

  @override
  Future<NativeTranscript?> load(AgentInfo agent) => window.loadOrAppend(
    statSize: () async => utf8.encode(contents).length,
    readRange: _readRange,
    parseLines: _parseLines,
    parseLine: _parseLine,
  );

  @override
  Future<NativeTranscript?> loadOlder(AgentInfo agent) =>
      window.loadOlder(readRange: _readRange, parseLines: _parseLines);

  Future<List<int>> _readRange(int offset, int? length) async {
    readOffsets.add(offset);
    readLengths.add(length);
    final bytes = utf8.encode(contents);
    if (offset > bytes.length) readEndOverrun = true;
    if (_blockFirstRead) {
      _blockFirstRead = false;
      firstReadStarted.complete();
      await releaseFirstRead.future;
    }
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
  }

  List<TranscriptEntry> _parseLines(String input) => const LineSplitter()
      .convert(input)
      .where((line) => line.isNotEmpty)
      .map(
        (line) =>
            TranscriptMessage(speaker: TranscriptSpeaker.user, text: line),
      )
      .toList();

  List<TranscriptEntry> _parseLine(String line) => line.isEmpty
      ? const []
      : [TranscriptMessage(speaker: TranscriptSpeaker.user, text: line)];
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
        final resolvedFor = <String?>[];
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

    test('serializes overlapping loads on one shared adapter', () async {
      final gate = Completer<void>();
      final adapter = _GatedHistoryAdapter(loadGate: gate);
      final history = NativeTranscriptHistory(
        _FakeCommandRunner(),
        resolveAdapter: (_) => _StubAdapter(adapter),
      );
      final agent = _agent('claude');

      final first = history.load(agent);
      await adapter.loadStarted.future;
      final second = history.load(agent);

      // The second call is queued at the history owner rather than reaching
      // the same stateful adapter/window while its first load is in flight.
      expect(adapter.loadCalls, 1);
      expect(adapter.concurrentAccessDetected, isFalse);

      gate.complete();
      await Future.wait([first, second]);

      expect(adapter.loadCalls, 2);
      expect(adapter.concurrentAccessDetected, isFalse);
      expect(adapter.events, [
        'load-start',
        'load-end',
        'load-start',
        'load-end',
      ]);
    });

    test(
      'loadOlder waits behind a session-changing load and rechecks identity',
      () async {
        final firstAdapter = _GatedHistoryAdapter();
        final secondGate = Completer<void>();
        final secondAdapter = _GatedHistoryAdapter(loadGate: secondGate);
        final resolvedSessions = <String>[];
        final history = NativeTranscriptHistory(
          _FakeCommandRunner(),
          resolveAdapter: (agent) {
            final session = agent.agentSession!.value;
            resolvedSessions.add(session);
            return _StubAdapter(
              session == 'first' ? firstAdapter : secondAdapter,
            );
          },
        );
        final first = _agent(
          'claude',
          agentSession: const AgentSession(
            source: 'claude',
            agent: 'claude',
            kind: 'id',
            value: 'first',
          ),
        );
        final second = _agent(
          'claude',
          agentSession: const AgentSession(
            source: 'claude',
            agent: 'claude',
            kind: 'id',
            value: 'second',
          ),
        );

        await history.load(first);
        final sessionChange = history.load(second);
        final olderFromOldSession = history.loadOlder(first);
        var olderCompleted = false;
        unawaited(
          olderFromOldSession.whenComplete(() => olderCompleted = true),
        );

        await secondAdapter.loadStarted.future;
        // The queued older request cannot mutate the old adapter while the
        // session-changing load is still resetting the shared owner.
        expect(olderCompleted, isFalse);
        expect(firstAdapter.loadOlderCalls, 0);

        secondGate.complete();
        await sessionChange;
        expect(await olderFromOldSession, isNull);
        expect(resolvedSessions, ['first', 'second']);
        expect(firstAdapter.loadOlderCalls, 0);
        expect(secondAdapter.loadOlderCalls, 0);
      },
    );

    test(
      'serializes a real window to avoid duplicate entries and read-end overrun',
      () async {
        final adapter = _GatedWindowHistoryAdapter('one\ntwo\n');
        final history = NativeTranscriptHistory(
          _FakeCommandRunner(),
          resolveAdapter: (_) => _StubAdapter(adapter),
        );
        final agent = _agent('claude');

        final first = history.load(agent);
        await adapter.firstReadStarted.future;
        final second = history.load(agent);
        expect(adapter.readOffsets, [0]);

        adapter.releaseFirstRead.complete();
        final snapshots = await Future.wait([first, second]);
        for (final snapshot in snapshots) {
          expect(snapshot!.messages.map((message) => message.text), [
            'one',
            'two',
          ]);
        }

        final originalLength = utf8.encode(adapter.contents).length;
        adapter.contents += 'three\n';
        final appended = await history.load(agent);

        expect(appended!.messages.map((message) => message.text), [
          'one',
          'two',
          'three',
        ]);
        expect(adapter.readOffsets, [0, originalLength]);
        expect(adapter.readLengths, [null, null]);
        expect(adapter.readEndOverrun, isFalse);
      },
    );
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
