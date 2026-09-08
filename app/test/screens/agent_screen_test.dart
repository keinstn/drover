import 'dart:async';
import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/agents/agent_adapter.dart';
import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/agent_native_history.dart';
import 'package:drover/src/demo/demo_herdr.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/herdr/host_platform.dart';
import 'package:drover/src/image/image_input.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/screens/agent_draft_store.dart';
import 'package:drover/src/screens/agent_screen.dart';
import 'package:drover/src/screens/structured_prompt_sheet.dart';
import 'package:drover/src/speech/speech_input.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/custom_divider.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// A valid 1x1 PNG so the composer's `Image.memory` preview can decode it in
/// widget tests (arbitrary bytes would throw during paint).
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class FakeImagePicker implements ImagePickerPort {
  FakeImagePicker({PickedImage? result})
    : result = result ?? PickedImage(bytes: _tinyPng, extension: 'png');

  /// Used by [pickImage] (camera), and as the sole gallery result when
  /// [galleryResult] isn't set.
  PickedImage? result;

  /// When set, [pickImages] (gallery) returns this instead of `[result]`,
  /// letting a single gallery pick stage several images at once.
  List<PickedImage>? galleryResult;

  final sources = <ImageAttachSource>[];
  var galleryCalls = 0;

  @override
  Future<PickedImage?> pickImage(ImageAttachSource source) async {
    sources.add(source);
    return result;
  }

  @override
  Future<List<PickedImage>> pickImages() async {
    galleryCalls++;
    if (galleryResult != null) return galleryResult!;
    return result == null ? [] : [result!];
  }
}

CommandResult workingResponse(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":[{"agent":"claude",'
      '"agent_status":"working","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}]}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok('working…');
  }
  return ok('{"id":"1","result":{}}');
}

/// An unrecognized agent ("mystery", say) whose pane happens to contain
/// Claude's own mode-line wording verbatim — no [AgentAdapter] supports it, so
/// its `AgentModeCapability`/`ImageAttachmentCapability` are both resolved as
/// null regardless of what the pane text looks like.
CommandResult unsupportedAgentModeResponse(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":[{"agent":"mystery",'
      '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}]}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(idleWithModeText);
  }
  return ok('{"id":"1","result":{}}');
}

/// The same blocked numbered-prompt pane text `blockedPromptResponse` serves,
/// but for an unrecognized agent — so AgentScreen must fall back to the
/// generic pane-text prompt parser rather than a Claude-specific dialog.
CommandResult unsupportedAgentBlockedResponse(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":[{"agent":"mystery",'
      '"agent_status":"blocked","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}]}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(blockedPromptText);
  }
  return ok('{"id":"1","result":{}}');
}

class FakeSpeechInput implements SpeechInput {
  FakeSpeechInput({this.startResult = const SpeechInputStartResult.started()});

  SpeechInputStartResult startResult;
  SpeechInputResultListener? _onResult;
  SpeechInputStatusListener? _onStatus;
  SpeechInputErrorListener? _onError;
  var stopCalls = 0;
  var cancelCalls = 0;

  @override
  Future<SpeechInputStartResult> start({
    required SpeechInputResultListener onResult,
    required SpeechInputStatusListener onStatus,
    required SpeechInputErrorListener onError,
  }) async {
    _onResult = onResult;
    _onStatus = onStatus;
    _onError = onError;
    return startResult;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  void result(String words, {bool isFinal = false}) {
    _onResult?.call(SpeechInputResult(words: words, isFinal: isFinal));
  }

  void done() => _onStatus?.call(SpeechInputStatus.done);

  void error(String message) => _onError?.call(message);
}

/// A claude pane whose mode line resolves to the widest mode pill label
/// ("Accept Edits"), so a narrow-screen layout test measures the composer's
/// button row at its worst case.
CommandResult acceptEditsModeResponse(String command) {
  if (command.contains("'agent' 'read'")) {
    return ok(
      'Working on the task…\n'
      '  -- INSERT -- ⏵⏵ accept edits on (shift+tab to cycle)\n',
    );
  }
  return workingResponse(command);
}

class NativeHistoryRunner extends StubCommandRunner {
  NativeHistoryRunner() : super(_response);

  String contents =
      '{"type":"user","message":{"role":"user","content":"Native question"}}\n'
      '{"type":"assistant","message":{"role":"assistant","content":['
      '{"type":"thinking","thinking":"hidden"},'
      '{"type":"text","text":"Native reply"}]}}\n';
  final readOffsets = <int>[];
  final readLengths = <int?>[];
  bool failNativeStat = false;

  static CommandResult _response(String command) {
    if (command.startsWith('command find ')) {
      return ok(
        '/home/dev/.claude/projects/-tmp-proj/'
        'c7c50b87-4d4c-4a92-9396-2cfa4158612d.jsonl\n',
      );
    }
    if (command.contains("'agent' 'list'")) {
      return ok(
        '{"id":"1","result":{"agents":[{"agent":"claude",'
        '"agent_status":"working","cwd":"/tmp/proj","focused":false,'
        '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
        '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
        '"value":"c7c50b87-4d4c-4a92-9396-2cfa4158612d"}}]}}',
      );
    }
    return workingResponse(command);
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    if (failNativeStat) {
      throw StateError('transient transcript access denied');
    }
    return RemoteFileStat(size: utf8.encode(contents).length);
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    readOffsets.add(offset);
    readLengths.add(length);
    final bytes = utf8.encode(contents);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
  }
}

class BrokenNativeHistoryRunner extends NativeHistoryRunner {
  @override
  Future<RemoteFileStat> statFile(String path) =>
      Future.error(StateError('transcript access denied'));
}

/// The pi flavour of [NativeHistoryRunner]: herdr reports pi's session as
/// `kind:'path'`, so there is no `command find` lookup at all — the loader
/// stats/reads the reported path directly, and these overrides refuse any
/// other path so a test can't pass on content served from the wrong file.
class PiNativeHistoryRunner extends StubCommandRunner {
  PiNativeHistoryRunner() : super(_response);

  static const path =
      '/home/dev/.pi/sessions/'
      '01a03d2d-e087-756b-809c-bc55bfaa7777.jsonl';

  String contents =
      '{"type":"session","version":3,'
      '"id":"01a03d2d-e087-756b-809c-bc55bfaa7777",'
      '"timestamp":"2026-08-26T08:26:51.911Z","cwd":"/tmp/proj"}\n'
      '{"type":"message","id":"a1","parentId":null,'
      '"timestamp":"2026-08-26T08:26:52.000Z","message":{"role":"user",'
      '"content":[{"type":"text","text":"Pi native question"}]}}\n'
      '{"type":"message","id":"a2","parentId":"a1",'
      '"timestamp":"2026-08-26T08:26:53.000Z","message":{"role":"assistant",'
      '"content":[{"type":"thinking","thinking":"hidden"},'
      '{"type":"text","text":"Pi native reply"},'
      '{"type":"toolCall","id":"call_abc","name":"bash",'
      '"arguments":{"command":"echo hello"}}]}}\n'
      '{"type":"message","id":"a3","parentId":"a2",'
      '"timestamp":"2026-08-26T08:26:54.000Z","message":{"role":"toolResult",'
      '"toolCallId":"call_abc","toolName":"bash",'
      '"content":[{"type":"text","text":"hello"}],"isError":false}}\n';

  static CommandResult _response(String command) {
    if (command.contains("'agent' 'list'")) {
      return ok(
        '{"id":"1","result":{"agents":[{"agent":"pi",'
        '"agent_status":"working","cwd":"/tmp/proj","focused":false,'
        '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
        '"agent_session":{"source":"herdr:pi","agent":"pi","kind":"path",'
        '"value":"$path"}}]}}',
      );
    }
    return workingResponse(command);
  }

  @override
  Future<RemoteFileStat> statFile(String requested) async {
    expect(requested, path);
    return RemoteFileStat(size: utf8.encode(contents).length);
  }

  @override
  Future<List<int>> readFile(
    String requested, {
    int offset = 0,
    int? length,
  }) async {
    expect(requested, path);
    final bytes = utf8.encode(contents);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
  }
}

/// A native-history runner whose `statFile` call (part of the
/// locate/stat/read/parse sequence) blocks on [nativeGate] until the test
/// completes it, so a widget test can assert on state while native history is
/// still loading without a real (unbounded) delay. An optional [readGate]
/// additionally blocks the pane `agent read` call, for asserting on the
/// state before *any* content (pane or native) has arrived.
class GatedNativeHistoryRunner extends NativeHistoryRunner {
  final nativeGate = Completer<void>();
  Completer<void>? readGate;

  @override
  Future<CommandResult> run(String command) async {
    if (command.contains("'agent' 'read'") && readGate != null) {
      await readGate!.future;
    }
    return super.run(command);
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    await nativeGate.future;
    return super.statFile(path);
  }
}

/// Fails the very first `agent get` call (as a herdr error envelope) and
/// succeeds on every call after, so a test can drive AgentScreen's first-load
/// outer-error path and then its retry.
class FlakyGetAgentRunner extends NativeHistoryRunner {
  var getAgentCalls = 0;

  @override
  Future<CommandResult> run(String command) async {
    if (command.contains("'agent' 'list'")) {
      getAgentCalls++;
      if (getAgentCalls == 1) {
        commands.add(command);
        return ok(
          '{"id":"1","result":{"error":{"code":"transport",'
          '"message":"boom"}}}',
        );
      }
    }
    return super.run(command);
  }
}

/// Serves a pane read whose lines are all present in the native conversation
/// ("Native question" / "Native reply"), so the live-terminal section is
/// suppressed as redundant.
class DuplicatePaneRunner extends NativeHistoryRunner {
  @override
  Future<CommandResult> run(String command) async {
    if (command.contains("'agent' 'read'")) {
      commands.add(command);
      return ok('Native question\nNative reply\n');
    }
    return super.run(command);
  }
}

/// Holds the Esc `send-keys` call open on [escGate] so a test can keep a
/// `_send` in flight (which disables the composer's Esc/Enter buttons) while
/// asserting the arrow-key row still works. Arrow keys resolve out of order
/// unless they're queued — 'down' is slow, every other arrow is instant — and
/// [arrowsCompleted] records them as they *finish*, so the order it ends up
/// with distinguishes a serialized queue from parallel sends.
class ArrowKeyRunner extends StubCommandRunner {
  ArrowKeyRunner() : super(workingResponse);

  final escGate = Completer<void>();
  final arrowsCompleted = <String>[];

  static const _arrows = ['left', 'up', 'down', 'right'];

  @override
  Future<CommandResult> run(String command) async {
    if (command.contains('send-keys')) {
      commands.add(command);
      if (command.contains("'esc'")) {
        await escGate.future;
        return ok('{"id":"1","result":{}}');
      }
      final arrow = _arrows.firstWhere(
        (a) => command.contains("'$a'"),
        orElse: () => '',
      );
      if (arrow.isNotEmpty) {
        // 'left' always fails, so a test can check the queue survives one.
        // Shaped the way HerdrClient actually detects a failure: an error
        // envelope on stderr (exit 0 with an envelope under `result` is not
        // an error to the client at all).
        if (arrow == 'left') {
          return const CommandResult(
            exitCode: 0,
            stdout: '',
            stderr:
                '{"error":{"code":"transport",'
                '"message":"arrow key rejected"}}',
          );
        }
        if (arrow == 'down') {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        arrowsCompleted.add(arrow);
        return ok('{"id":"1","result":{}}');
      }
    }
    return super.run(command);
  }
}

/// The question text of [_singleAskUserJsonl], reused by the read override so
/// the submitter's initial-screen and dialog-closed confirmations both pass.
const _askUserQuestionText = 'Which environment should I deploy to?';

/// A session ending in a lone single-select AskUserQuestion (no tool_result),
/// so the sheet auto-presents and a real submit can drive to success.
final _singleAskUserJsonl =
    '${[
      '{"type":"user","message":{"role":"user","content":"Deploy please"}}',
      jsonEncode({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'name': 'AskUserQuestion',
              'id': 'toolu_single',
              'input': {
                'questions': [
                  {
                    'question': _askUserQuestionText,
                    'header': 'Environment',
                    'multiSelect': false,
                    'options': [
                      {'label': 'Staging'},
                      {'label': 'Production'},
                    ],
                  },
                ],
              },
            },
          ],
        },
      }),
    ].join('\n')}\n';

/// The tool_result that marks [_singleAskUserJsonl]'s question answered.
const _singleAskUserAnswered =
    '{"type":"user","message":{"role":"user","content":['
    '{"type":"tool_result","tool_use_id":"toolu_single"}]}}\n';

/// Serves [_singleAskUserJsonl] and drives the read-driven submitter to a
/// success: `agent read` returns the open dialog (question text + the "Esc to
/// cancel" chrome the submitter gates on) until the answer digit is sent via
/// `pane send-text`, after which it returns a closed screen — so the initial
/// confirm and the final dialog-closed confirm both pass.
class AskUserSubmitRunner extends NativeHistoryRunner {
  AskUserSubmitRunner() {
    contents = _singleAskUserJsonl;
  }

  bool _answerSent = false;

  @override
  Future<CommandResult> run(String command) async {
    if (command.contains("'pane' 'send-text'")) {
      _answerSent = true;
      return super.run(command);
    }
    if (command.contains("'agent' 'read'")) {
      commands.add(command);
      final text = _answerSent
          ? 'All set.'
          : '$_askUserQuestionText\nEsc to cancel';
      return ok(text);
    }
    return super.run(command);
  }
}

/// JSONL for a single assistant turn carrying [text].
String _assistantJsonl(String text) =>
    '${jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    })}\n';

/// Pumps an [AgentScreen] whose only native turn is an assistant message
/// carrying [text], then settles and lets the off-isolate code highlighter
/// deliver its result. Fenced code is highlighted via [compute], which only
/// runs under [WidgetTester.runAsync]; blocks render plain until it lands.
Future<void> _pumpAssistant(WidgetTester tester, String text) async {
  final client = HerdrClient(
    NativeHistoryRunner()..contents = _assistantJsonl(text),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
      home: AgentScreen(
        client: client,
        paneId: 'wB:p1',
        pollInterval: const Duration(hours: 1),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 800)),
  );
  await tester.pumpAndSettle();
}

/// The [RichText] whose flattened text contains [needle], or null.
RichText? _richTextContaining(WidgetTester tester, String needle) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    if (rich.text.toPlainText().contains(needle)) return rich;
  }
  return null;
}

/// Distinct foreground colours across [root], merging inherited styles so the
/// count reflects what actually paints.
Set<Color> _spanColors(InlineSpan root) {
  final colors = <Color>{};
  void walk(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    final merged = inherited.merge(span.style);
    if ((span.text ?? '').isNotEmpty && merged.color != null) {
      colors.add(merged.color!);
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, merged);
    }
  }

  walk(root, const TextStyle());
  return colors;
}

/// The effective font size of the first span whose text contains [needle].
double? _fontSizeOfText(InlineSpan root, String needle) {
  double? found;
  void walk(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    final merged = inherited.merge(span.style);
    if (found == null && (span.text ?? '').contains(needle)) {
      found = merged.fontSize;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, merged);
    }
  }

  walk(root, const TextStyle());
  return found;
}

/// Pumps an [AgentScreen] whose native session serves [contents] verbatim.
Future<void> _pumpNative(WidgetTester tester, String contents) async {
  final client = HerdrClient(NativeHistoryRunner()..contents = contents);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
      home: AgentScreen(
        client: client,
        paneId: 'wB:p1',
        pollInterval: const Duration(hours: 1),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// JSONL for a single assistant turn carrying one tool_use block.
String _toolUseJsonl(String name, Map<String, dynamic> input) =>
    '${jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'tool_use', 'name': name, 'input': input},
        ],
      },
    })}\n';

/// JSONL for a single assistant turn carrying one thinking block.
String _thinkingJsonl(String text) =>
    '${jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': text},
        ],
      },
    })}\n';

/// A [NativeTranscriptAdapter] test double whose [load] returns a fixed
/// "recent" window and whose [loadOlder] pages through [olderChunks] one at a
/// time, prepending each in order — standing in for the real bounded-window
/// loaders (`ClaudeTranscriptLoader`/`CopilotTranscriptLoader`) so AgentScreen's
/// pull-to-load-more dispatch/anchoring can be tested without a multi-hundred
/// KiB fixture.
class _PagedNativeAdapter implements NativeTranscriptAdapter {
  _PagedNativeAdapter(this._transcript);

  NativeTranscript _transcript;
  final olderChunks = <List<TranscriptEntry>>[];
  var loadOlderCalls = 0;

  @override
  Future<NativeTranscript?> load(AgentInfo agent) async => _transcript;

  @override
  bool get hasOlderHistory => loadOlderCalls < olderChunks.length;

  @override
  Future<NativeTranscript?> loadOlder(AgentInfo agent) async {
    if (!hasOlderHistory) return null;
    final chunk = olderChunks[loadOlderCalls];
    loadOlderCalls++;
    _transcript = NativeTranscript([...chunk, ..._transcript.entries]);
    return _transcript;
  }
}

/// An [AgentAdapter] that always hands back [history] as the native-history
/// capability, regardless of [agent].
class _FixedNativeHistoryAdapter extends AgentAdapter {
  _FixedNativeHistoryAdapter(this.history);

  final NativeTranscriptAdapter history;

  @override
  bool supports(AgentInfo agent) => true;

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    HostPlatform platform,
    AgentInfo agent,
  ) => history;
}

/// A [NativeTranscriptAdapter] test double standing in for a real adapter's
/// single, shared `JsonlTranscriptWindow` — [load] and [loadOlder] both
/// record entry/exit into [_busy] and flag [concurrentAccessDetected] if
/// either is called while the other is still in flight, exactly the hazard
/// a real window's byte-offset/entries state can't survive. [load] pauses on
/// [pendingLoad] (when set) before resolving, letting a test hold a poll
/// "mid-flight" to prove a concurrent pull-to-load-more is correctly gated
/// out rather than racing it.
class _GatedNativeAdapter implements NativeTranscriptAdapter {
  _GatedNativeAdapter(this._transcript);

  NativeTranscript _transcript;
  final olderChunks = <List<TranscriptEntry>>[];
  Completer<void>? pendingLoad;
  var loadCalls = 0;
  var loadOlderCalls = 0;
  var _busy = false;
  var concurrentAccessDetected = false;

  @override
  Future<NativeTranscript?> load(AgentInfo agent) async {
    loadCalls++;
    return _guarded(() async {
      final gate = pendingLoad;
      if (gate != null) await gate.future;
      return _transcript;
    });
  }

  @override
  bool get hasOlderHistory => loadOlderCalls < olderChunks.length;

  @override
  Future<NativeTranscript?> loadOlder(AgentInfo agent) {
    if (!hasOlderHistory) return Future.value(null);
    return _guarded(() async {
      final chunk = olderChunks[loadOlderCalls];
      loadOlderCalls++;
      _transcript = NativeTranscript([...chunk, ..._transcript.entries]);
      return _transcript;
    });
  }

  Future<NativeTranscript?> _guarded(
    Future<NativeTranscript?> Function() body,
  ) async {
    if (_busy) concurrentAccessDetected = true;
    _busy = true;
    try {
      return await body();
    } finally {
      _busy = false;
    }
  }
}

/// A two-agent `agent list` (wB:p1 claude "Alpha" current + wA:p1 codex
/// "Database"), so the bottom switcher bar is visible and the switch/label
/// behaviours can be exercised. Serves workspace labels and a generic pane read
/// for whichever pane is current.
CommandResult multiAgentResponse(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":['
      '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-b",'
      '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"terminal_title_stripped":"Alpha"},'
      '{"agent":"codex","agent_status":"working","cwd":"/tmp/proj-a",'
      '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA",'
      '"terminal_title_stripped":"Database"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok('multi-agent pane text');
  }
  return ok('{"id":"1","result":{}}');
}

void main() {
  // Tests that don't inject their own store fall back to AgentDraftStore.shared,
  // and any draft a test types is persisted there on dispose. Reset the shared
  // draft for the common paneId before each test so that leak never carries a
  // stale draft into a later test's composer.
  setUp(() {
    AgentDraftStore.shared.clear('wB:p1');
    AgentDraftStore.shared.keysRowOpen = false;
  });

  testWidgets('renders native Claude history with a separated live terminal', (
    tester,
  ) async {
    final runner = NativeHistoryRunner();
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(runner.commands, isNotEmpty);
    expect(runner.readOffsets, [0]);
    expect(find.text('CONVERSATION HISTORY'), findsOneWidget);
    expect(find.text('Native question'), findsOneWidget);
    // The assistant reply is Markdown-rendered (a RichText, not a Text widget).
    expect(
      find.textContaining('Native reply', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('LIVE TERMINAL'), findsOneWidget);
    expect(find.text('working…'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('CONVERSATION HISTORY')).dy,
      lessThan(tester.getTopLeft(find.text('LIVE TERMINAL')).dy),
    );
    expect(
      tester.getTopLeft(find.text('LIVE TERMINAL')).dy,
      lessThan(tester.getTopLeft(find.text('working…')).dy),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'renders assistant turns as Markdown and user turns as plain bubbles',
    (tester) async {
      final client = HerdrClient(NativeHistoryRunner());

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Only the assistant reply goes through GptMarkdown.
      expect(find.byType(GptMarkdown), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GptMarkdown),
          matching: find.textContaining('Native reply', findRichText: true),
        ),
        findsOneWidget,
      );
      // The user turn stays a plain (non-Markdown) selectable bubble.
      expect(find.text('Native question'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GptMarkdown),
          matching: find.text('Native question'),
        ),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('right-aligns user turns', (tester) async {
    final client = HerdrClient(NativeHistoryRunner());

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final align = tester.widget<Align>(
      find
          .ancestor(
            of: find.text('Native question'),
            matching: find.byType(Align),
          )
          .first,
    );
    expect(align.alignment, Alignment.centerRight);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a fenced code block without overflow', (tester) async {
    final longLine = 'final value = ${'x' * 200};';
    final runner = NativeHistoryRunner()
      ..contents =
          '${jsonEncode({
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': '# Heading\n\n**bold** and `inline`\n\n- one\n- two\n\n'
                    '```dart\n$longLine\n```'},
              ],
            },
          })}\n';
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.textContaining('final value ='), findsOneWidget);
    // A layout overflow would surface as a thrown exception during layout.
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('syntax-highlights a dart fence with multiple colours', (
    tester,
  ) async {
    await _pumpAssistant(
      tester,
      '```dart\nvoid main() {\n  final x = 42;\n  print(x);\n}\n```',
    );

    final code = _richTextContaining(tester, 'void main');
    expect(code, isNotNull);
    // More than one foreground colour means the highlighter coloured the tokens
    // rather than falling back to a single plain style.
    expect(_spanColors(code!.text).length, greaterThan(1));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders an unknown-language fence as plain text (no throw)', (
    tester,
  ) async {
    await _pumpAssistant(tester, '```zzz\nsome unknown code\n```');

    expect(find.textContaining('some unknown code'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a diff fence without throwing', (tester) async {
    await _pumpAssistant(
      tester,
      '```diff\n-old removed line\n+new added line\n```',
    );

    expect(
      find.textContaining('new added line', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders an over-cap fence as plain text without highlighting', (
    tester,
  ) async {
    // Over the 20k pre-check: highlighting is skipped entirely (no isolate
    // work), so the raw code renders immediately as plain text.
    final huge = 'x' * 20001;
    final client = HerdrClient(
      NativeHistoryRunner()
        ..contents = _assistantJsonl('```dart\n// MARKER\n$huge\n```'),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('MARKER'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scales an h2 heading to chat proportions', (tester) async {
    await _pumpAssistant(tester, '## Title');

    final heading = _richTextContaining(tester, 'Title');
    expect(heading, isNotNull);
    expect(_fontSizeOfText(heading!.text, 'Title'), 18);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('does not add a divider after an h1 heading', (tester) async {
    await _pumpAssistant(tester, '# Title');

    expect(find.textContaining('Title', findRichText: true), findsOneWidget);
    // gpt_markdown draws the auto h1 divider as a CustomDivider; disabled here.
    expect(find.byType(CustomDivider), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders transcript images as an inert placeholder (no network)', (
    tester,
  ) async {
    final runner = NativeHistoryRunner()
      ..contents =
          '${jsonEncode({
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': '![x](https://example.invalid/x.png)'},
              ],
            },
          })}\n';
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Untrusted transcript images must never build an Image (which would GET
    // the URL); they render as an inert placeholder showing the URL instead.
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('example.invalid'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hides the native section when the parsed history is empty', (
    tester,
  ) async {
    // A record whose content yields no entries at all (an empty content array),
    // as opposed to a thinking/tool_use-only turn, which now counts as history.
    final runner = NativeHistoryRunner()
      ..contents =
          '{"type":"assistant","message":{"role":"assistant","content":[]}}';
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // An empty-but-present native history is treated as absent: no header, and
    // the pane fallback still renders.
    expect(find.text('CONVERSATION HISTORY'), findsNothing);
    expect(find.text('working…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the native section for a tool_use-only history', (
    tester,
  ) async {
    await _pumpNative(
      tester,
      _toolUseJsonl('Read', {'file_path': 'lib/main.dart'}),
    );

    // A history with no chat messages, only a tool_use, still counts.
    expect(find.text('CONVERSATION HISTORY'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders task_complete summary as assistant transcript text', (
    tester,
  ) async {
    await _pumpNative(
      tester,
      _toolUseJsonl('task_complete', {
        'summary': '  All requested changes are now complete.  ',
        'other': 'kept in input',
      }),
    );

    expect(find.text('CONVERSATION HISTORY'), findsOneWidget);
    expect(
      find.text('All requested changes are now complete.'),
      findsOneWidget,
    );
    expect(find.text('task_complete'), findsNothing);
    expect(find.byIcon(Icons.build), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('falls back to chip for task_complete without valid summary', (
    tester,
  ) async {
    await _pumpNative(
      tester,
      _toolUseJsonl('task_complete', {'summary': '   '}),
    );

    expect(find.text('CONVERSATION HISTORY'), findsOneWidget);
    expect(find.text('task_complete'), findsOneWidget);
    expect(find.byIcon(Icons.build), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a tool_use chip and toggles its detail on tap', (
    tester,
  ) async {
    await _pumpNative(
      tester,
      _toolUseJsonl('Bash', {'command': 'echo hello', 'description': 'say hi'}),
    );

    // The chip shows the tool name and its one-line summary.
    expect(find.text('Bash'), findsOneWidget);
    expect(find.textContaining('echo hello'), findsWidgets);
    // Collapsed by default: the pretty-printed input is not shown.
    expect(find.textContaining('"command"'), findsNothing);

    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"command"'), findsOneWidget);

    // A second tap collapses it again.
    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"command"'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expands an Edit tool_use into a diff card', (tester) async {
    await _pumpNative(
      tester,
      _toolUseJsonl('Edit', {
        'file_path': 'lib/main.dart',
        'old_string': 'old line one\nold line two',
        'new_string': 'new line one\nnew line two',
      }),
    );

    expect(find.text('Edit'), findsOneWidget);
    expect(find.textContaining('old line one'), findsNothing);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // The diff card renders both the removed and the added lines.
    expect(find.textContaining('old line one'), findsOneWidget);
    expect(find.textContaining('old line two'), findsOneWidget);
    expect(find.textContaining('new line one'), findsOneWidget);
    expect(find.textContaining('new line two'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a thinking row collapsed and expands it on tap', (
    tester,
  ) async {
    await _pumpNative(tester, _thinkingJsonl('my private reasoning'));

    // Collapsed by default: the label shows but the thinking body is hidden.
    expect(find.text('Thinking…'), findsOneWidget);
    expect(find.textContaining('my private reasoning'), findsNothing);

    await tester.tap(find.text('Thinking…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('my private reasoning'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expands a tool_use with non-finite JSON without throwing', (
    tester,
  ) async {
    // Out-of-range literals decode to double.infinity; the detail must still
    // render (via the toEncodable fallback) rather than throw every poll.
    await _pumpNative(
      tester,
      '{"type":"assistant","message":{"role":"assistant","content":['
      '{"type":"tool_use","name":"Bash","input":'
      '{"command":"echo hi","ceiling":1e999}}]}}\n',
    );

    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Infinity'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('caps a large Write diff and shows a truncation footer', (
    tester,
  ) async {
    final content = List.generate(500, (i) => 'line $i').join('\n');
    await _pumpNative(
      tester,
      _toolUseJsonl('Write', {'file_path': 'big.txt', 'content': content}),
    );

    await tester.tap(find.text('Write'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Rendered lines cap at 200; the remaining 300 are summarised in a footer.
    expect(find.text('… +300 lines'), findsOneWidget);
    expect(find.textContaining('line 0'), findsWidgets);
    expect(find.textContaining('line 499'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps a tool_use chip expanded across an appending poll', (
    tester,
  ) async {
    final runner = NativeHistoryRunner()
      ..contents = _toolUseJsonl('Bash', {'command': 'echo hello'});
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"command"'), findsOneWidget);

    // A later poll appends a new entry; the loader keeps the tool_use instance,
    // so the chip's index/name/summary key is stable and it stays expanded.
    runner.contents =
        '${runner.contents}'
        '{"type":"user","message":{"role":"user","content":"a new turn"}}\n';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('a new turn'), findsOneWidget);
    expect(find.textContaining('"command"'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a pi pane\'s native transcript, including its append', (
    tester,
  ) async {
    final runner = PiNativeHistoryRunner();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: HerdrClient(runner),
          paneId: 'wB:p1',
          pollInterval: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The leading `type:"session"` record is skipped without derailing the
    // message records that follow it.
    expect(find.text('Pi native question'), findsOneWidget);
    expect(find.text('Pi native reply'), findsOneWidget);

    await tester.tap(find.text('bash'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"command"'), findsOneWidget);

    runner.contents =
        '${runner.contents}'
        '{"type":"message","id":"a4","parentId":"a3",'
        '"timestamp":"2026-08-26T08:26:55.000Z","message":{"role":"user",'
        '"content":[{"type":"text","text":"Pi follow-up"}]}}\n';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Pi follow-up'), findsOneWidget);
    expect(find.text('Pi native question'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'builds only nearby native Markdown entries until they are scrolled into view',
    (tester) async {
      final runner = StubCommandRunner(workingResponse);
      final entries = List.generate(
        300,
        (index) => TranscriptMessage(
          speaker: TranscriptSpeaker.assistant,
          text: 'Far assistant turn $index',
        ),
      );
      final adapter = _PagedNativeAdapter(NativeTranscript(entries));
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: HerdrClient(runner),
            paneId: 'wB:p1',
            pollInterval: const Duration(seconds: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The screen opens at the live bottom. A SliverList only creates the
      // viewport's Markdown widgets rather than all 300 parsed entries.
      expect(find.byType(GptMarkdown).evaluate().length, lessThan(40));
      expect(
        find.textContaining('Far assistant turn 0', findRichText: true),
        findsNothing,
      );

      // A poll rebuilding the screen leaves that bound intact.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(GptMarkdown).evaluate().length, lessThan(40));

      final scroll = find.byKey(const ValueKey('transcript_scroll'));
      await tester.drag(scroll, const Offset(0, 100000));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Far assistant turn 0', findRichText: true),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'preserves the native viewport anchor when an older page is prepended',
    (tester) async {
      final runner = StubCommandRunner(workingResponse);
      final recent = List.generate(
        10,
        (index) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Recent anchor turn $index, with enough filler to occupy a '
              'distinct transcript row.',
        ),
      );
      final older = List.generate(
        10,
        (index) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Older anchor turn $index, with enough filler to occupy a '
              'distinct transcript row.',
        ),
      );
      final adapter = _PagedNativeAdapter(NativeTranscript(recent))
        ..olderChunks.add(older);
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: HerdrClient(runner),
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scroll = find.byKey(const ValueKey('transcript_scroll'));
      await tester.drag(scroll, const Offset(0, 10000));
      await tester.pumpAndSettle();
      final anchor = find.textContaining('Recent anchor turn 0');
      final before = tester.getTopLeft(anchor).dy;

      await tester.fling(scroll, const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      expect(adapter.loadOlderCalls, 1);
      expect(anchor, findsOneWidget);
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
      await tester.drag(scroll, const Offset(0, 100000));
      await tester.pumpAndSettle();
      expect(find.textContaining('Older anchor turn 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'keeps tool and thinking expansion with their entries across poll and prepend',
    (tester) async {
      final runner = StubCommandRunner(workingResponse);
      final tool = TranscriptToolUse(
        name: 'Bash',
        input: {'command': 'echo retained expansion'},
      );
      const thinking = TranscriptThinking('retained private reasoning');
      final adapter = _PagedNativeAdapter(NativeTranscript([tool, thinking]))
        ..olderChunks.add(
          List.generate(
            4,
            (index) => TranscriptMessage(
              speaker: TranscriptSpeaker.user,
              text: 'Older entry $index',
            ),
          ),
        );
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: HerdrClient(runner),
            paneId: 'wB:p1',
            pollInterval: const Duration(seconds: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Bash'));
      await tester.tap(find.text('Thinking…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"command"'), findsOneWidget);
      expect(find.textContaining('retained private reasoning'), findsOneWidget);

      // The poll returns the same entry objects, so both expanded rows remain
      // expanded before history is prepended.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('"command"'), findsOneWidget);
      expect(find.textContaining('retained private reasoning'), findsOneWidget);

      final scroll = find.byKey(const ValueKey('transcript_scroll'));
      await tester.fling(scroll, const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      // Prepending shifts the entries' indices, but their ObjectKeys and the
      // delegate's index lookup keep the state on the matching entries.
      expect(adapter.loadOlderCalls, 1);
      expect(find.textContaining('"command"'), findsOneWidget);
      expect(find.textContaining('retained private reasoning'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'hides the live terminal when the pane duplicates native history',
    (tester) async {
      final client = HerdrClient(DuplicatePaneRunner());

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The native section shows, but the pane (all lines already present in the
      // native conversation) is suppressed — no live-terminal section at all.
      expect(find.text('CONVERSATION HISTORY'), findsOneWidget);
      expect(find.text('Native question'), findsOneWidget);
      expect(find.text('LIVE TERMINAL'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'keeps the live terminal visible when an old, unrelated native turn '
    "happens to share short substrings with the pane's lines, as long as "
    "enough recent history pushes it out of the comparison window "
    '(regression: the duplicate check must not compare against unbounded '
    'history — see the char-budget cap pull-to-refresh would otherwise '
    'defeat)',
    (tester) async {
      CommandResult unrelatedPaneResponse(String command) {
        if (command.contains("'agent' 'read'")) {
          return ok('Building the project\nRunning tests now\n');
        }
        return workingResponse(command);
      }

      final runner = StubCommandRunner(unrelatedPaneResponse);
      final client = HerdrClient(runner);
      // An unrelated old turn that happens to contain both pane lines
      // verbatim — the kind of coincidental short-substring match that,
      // without a bounded comparison window, would trip the duplicate
      // threshold once it's part of the loaded history (e.g. paged in via
      // pull-to-refresh).
      final oldUnrelatedMessage = const TranscriptMessage(
        speaker: TranscriptSpeaker.user,
        text:
            'Long unrelated turn from a while back. Building the project '
            'used to fail here for a completely different reason. Running '
            'tests now was also flaky in that old run.',
      );
      // Padded well past the dedup char budget on its own, so it occupies
      // the entire comparison window and the old message above never enters
      // it — standing in for a long recent conversation that has
      // accumulated since that old turn.
      final recentFiller = List.generate(
        30,
        (i) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Recent filler turn $i: '
              '${List.filled(20, 'padding text to grow this history entry well past the dedup budget. ').join()}',
        ),
      );
      final adapter = _PagedNativeAdapter(
        NativeTranscript([oldUnrelatedMessage, ...recentFiller]),
      );
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The old message coincidentally contains both pane lines verbatim,
      // but it's pushed out of the bounded comparison window by the recent
      // filler history — the Live terminal section must stay visible rather
      // than being hidden as "duplicate".
      expect(find.text('LIVE TERMINAL'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('falls back to pane history when native metadata is absent', (
    tester,
  ) async {
    final client = HerdrClient(StubCommandRunner(workingResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('working…'), findsOneWidget);
    expect(find.text('CONVERSATION HISTORY'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows native load errors while keeping pane fallback', (
    tester,
  ) async {
    final client = HerdrClient(BrokenNativeHistoryRunner());

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('working…'), findsOneWidget);
    // The native-history banner now renders via ErrorMessageView, whose
    // headline for an unknown-kind error is the raw technical detail.
    expect(find.textContaining('transcript access denied'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows pane text while native history is still loading', (
    tester,
  ) async {
    final runner = GatedNativeHistoryRunner();
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );

    // The fast pane path (agent get + pane read) resolves without waiting on
    // native history, whose `statFile` call is still gated shut.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('working…'), findsOneWidget);
    expect(find.text('Native question'), findsNothing);
    expect(
      find.byKey(const ValueKey('transcript_initial_loading')),
      findsNothing,
    );

    runner.nativeGate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Native question'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows an initial loading state before any content arrives', (
    tester,
  ) async {
    final runner = GatedNativeHistoryRunner();
    final client = HerdrClient(runner);
    final gate = Completer<void>();
    runner.readGate = gate;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('transcript_initial_loading')),
      findsOneWidget,
    );
    expect(find.text('working…'), findsNothing);

    gate.complete();
    runner.nativeGate.complete();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('transcript_initial_loading')),
      findsNothing,
    );
    expect(find.text('working…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'surfaces a first-load outer failure with a retry action, without '
    'a silent blank screen',
    (tester) async {
      final runner = FlakyGetAgentRunner();
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The load-error banner now renders via ErrorMessageView, whose headline
      // for an unknown-kind HerdrException is the raw technical detail.
      expect(find.textContaining('missing agents field'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transcript_initial_loading')),
        findsNothing,
      );
      expect(find.text('working…'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(find.textContaining('missing agents field'), findsNothing);
      expect(find.text('working…'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('keeps native history visible when a later native stat fails', (
    tester,
  ) async {
    final runner = NativeHistoryRunner();
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Native question'), findsOneWidget);

    runner.failNativeStat = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Native question'), findsOneWidget);
    expect(
      find.textContaining('Native reply', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('working…'), findsOneWidget);
    // The native-history banner now renders via ErrorMessageView, whose
    // headline for an unknown-kind error is the raw technical detail.
    expect(find.textContaining('transcript access denied'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows retained-history notice when pane load-more has no text', (
    tester,
  ) async {
    final client = HerdrClient(StubCommandRunner(workingResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('transcript_scroll')),
      const Offset(0, 300),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text('Beginning of retained terminal history reached'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'loads more pane history when the native transcript has no entries',
    (tester) async {
      // An empty content array parses to zero entries, so there is no history
      // to gate on and pull-to-load-more falls through to the pane. A
      // thinking/tool_use-only turn now counts as history and would block it.
      final runner = NativeHistoryRunner()
        ..contents =
            '{"type":"assistant","message":{"role":"assistant","content":[]}}';
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('working…'), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 1000),
      );
      await tester.pump();
      await tester.fling(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(
        runner.commands.any(
          (command) =>
              command.contains("'agent' 'read'") && command.contains("'360'"),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shows prompt options and sends the chosen number', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Yes'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'No'), findsOneWidget);
    expect(find.text('claude · Project B'), findsOneWidget);
    // The status pill rides the label ramp too, so English uppercases it.
    expect(find.text('WAITING FOR YOU'), findsOneWidget);
    expect(find.textContaining('p1'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Yes'));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains("agent' 'prompt'") && c.contains("'1'"),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps the draft and shows an error when send fails', (
    tester,
  ) async {
    CommandResult respondFailingSend(String command) {
      if (command.contains("'agent' 'prompt'")) {
        return const CommandResult(exitCode: 1, stdout: '', stderr: 'boom');
      }
      return blockedPromptResponse(command);
    }

    final runner = StubCommandRunner(respondFailingSend);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'please continue');
    await tester.tap(find.byKey(const ValueKey('send_message_button')));
    await tester.pump();
    await tester.pump();

    expect(find.text('please continue'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a mode button that cycles the agent mode', (tester) async {
    final runner = StubCommandRunner(idleWithModeResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Mode is now a dedicated button; the old Enter/Esc chips are gone.
    expect(find.byKey(const ValueKey('cycle_mode_button')), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Enter'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Esc'), findsNothing);

    // Tapping the mode button cycles it by sending the raw backtab escape
    // sequence via `pane send-text` (on drover's herdr floor of 0.8.0,
    // `send-keys shift+tab` mis-encodes it — see herdr issue #1561).
    await tester.tap(find.byKey(const ValueKey('cycle_mode_button')));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains("'pane' 'send-text'") && c.contains('\u001b[Z'),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('turns send into a stop button that interrupts with Esc', (
    tester,
  ) async {
    final runner = StubCommandRunner(workingResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // A working agent with an empty input shows a stop button, not send.
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);

    await tester.tap(find.byKey(const ValueKey('send_message_button')));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'esc'"),
      ),
      isTrue,
    );

    // Typing a message turns it back into a send button.
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sends Esc from the escape button when idle', (tester) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The agent is not running, so the send/stop button is not in stop mode.
    expect(find.byIcon(Icons.stop), findsNothing);

    // Esc lives in the collapsible key row, so open it first.
    await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
    await tester.pumpAndSettle();

    // The dedicated escape button is present regardless and sends Esc.
    expect(find.byKey(const ValueKey('send_escape_button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('send_escape_button')));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'esc'"),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sends Enter from the enter button when idle', (tester) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Enter lives in the collapsible key row, so open it first.
    await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
    await tester.pumpAndSettle();

    // The dedicated enter button is present regardless of agent status and
    // sends a raw Enter, letting the user execute a prompt already staged in
    // the pane's own input line.
    expect(find.byKey(const ValueKey('send_enter_button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('send_enter_button')));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'enter'"),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('places Esc button before Enter button in the key row', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
    await tester.pumpAndSettle();

    final escDx = tester
        .getTopLeft(find.byKey(const ValueKey('send_escape_button')))
        .dx;
    final enterDx = tester
        .getTopLeft(find.byKey(const ValueKey('send_enter_button')))
        .dx;
    expect(escDx, lessThan(enterDx));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps send (not stop) when a working agent has a staged image', (
    tester,
  ) async {
    final runner = StubCommandRunner(workingResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Working agent, empty input → stop button.
    expect(find.byIcon(Icons.stop), findsOneWidget);

    // Staging an image (with no caption) must flip it back to a send button so
    // the image can actually be sent rather than interrupting the agent.
    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    await tester.tap(find.byKey(const ValueKey('send_message_button')));
    await tester.pump();
    await tester.pump();

    // The image was sent and no Esc interrupt was issued.
    expect(runner.uploads.any((u) => !u.path.endsWith('.gitignore')), isTrue);
    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'esc'"),
      ),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offers photo and camera sources on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('attach_from_library')), findsOneWidget);
    expect(find.byKey(const ValueKey('attach_from_camera')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('attach_from_camera')));
    await tester.pumpAndSettle();

    // The chosen source reaches the picker and the shot is staged.
    expect(imagePicker.sources, [ImageAttachSource.camera]);
    expect(find.byKey(const ValueKey('remove_image_button_0')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('appends dictated partial text to the existing draft', (
    tester,
  ) async {
    final speech = FakeSpeechInput();
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Please ');

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    speech.result('continue the task');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Please continue the task',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replaces cumulative dictated partial results', (tester) async {
    final speech = FakeSpeechInput();
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Please');

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    speech.result('continue');
    await tester.pump();
    speech.result('continue the task');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Please continue the task',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disables sending while dictation is active', (tester) async {
    final speech = FakeSpeechInput();
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();

    final send = tester.widget<FilledButton>(
      find.byKey(const ValueKey('send_message_button')),
    );
    expect(send.onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stopping dictation returns the draft for review', (
    tester,
  ) async {
    final speech = FakeSpeechInput();
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Please');

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    speech.result('continue');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    speech.done();
    await tester.pump();

    expect(speech.stopCalls, 1);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Please continue',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a speech setup failure without changing the draft', (
    tester,
  ) async {
    final speech = FakeSpeechInput(
      startResult: const SpeechInputStartResult.failed(
        'Speech recognition is unavailable or permission was denied.',
      ),
    );
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Keep this draft');

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this draft',
    );
    expect(
      find.text('Speech recognition is unavailable or permission was denied.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps the draft when recognition reports an error', (
    tester,
  ) async {
    final speech = FakeSpeechInput();
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Keep this draft');

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    speech.error('Speech recognition failed: no service');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this draft',
    );
    expect(find.text('Speech recognition failed: no service'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancels active dictation when the screen is disposed', (
    tester,
  ) async {
    final speech = FakeSpeechInput();
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          speechInput: speech,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());

    expect(speech.cancelCalls, 1);
  });

  testWidgets('stages multiple picked images without sending them', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();
    imagePicker.result = PickedImage(bytes: _tinyPng, extension: 'jpg');
    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();

    // Picking stages both images (two removable previews appear) but sends
    // nothing.
    expect(find.byKey(const ValueKey('remove_image_button_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('remove_image_button_1')), findsOneWidget);
    expect(runner.uploads, isEmpty);
    expect(runner.commands.any((c) => c.contains("'agent' 'send'")), isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a single gallery pick can stage multiple images at once', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker()
      ..galleryResult = [
        PickedImage(bytes: _tinyPng, extension: 'png'),
        PickedImage(bytes: _tinyPng, extension: 'jpg'),
      ];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // On non-iOS platforms tapping the attach button goes straight to the
    // gallery (no source menu), and one pick can return several images.
    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();

    expect(imagePicker.galleryCalls, 1);
    expect(find.byKey(const ValueKey('remove_image_button_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('remove_image_button_1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sends the staged images and text together on send', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'look at this');
    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();
    imagePicker.result = PickedImage(bytes: _tinyPng, extension: 'jpg');
    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();
    expect(runner.uploads, isEmpty); // still staged, not sent

    await tester.tap(find.byKey(const ValueKey('send_message_button')));
    await tester.pump();
    await tester.pump();

    final imageUploads = runner.uploads
        .where((u) => !u.path.endsWith('.gitignore'))
        .toList();
    expect(imageUploads, hasLength(2));
    for (final upload in imageUploads) {
      expect(upload.path, startsWith('/tmp/proj/.drover/'));
      expect(upload.bytes, _tinyPng);
    }
    expect(
      runner.uploads.any((u) => u.path == '/tmp/proj/.drover/.gitignore'),
      isTrue,
    );
    expect(
      runner.commands.where((c) => c.contains("'agent' 'prompt'")).length,
      1,
    );
    expect(
      runner.commands.any(
        (c) =>
            c.contains("'agent' 'prompt'") &&
            c.contains('.drover') &&
            c.contains('look at this'),
      ),
      isTrue,
    );
    // The staged images are cleared after a successful send.
    expect(find.byKey(const ValueKey('remove_image_button_0')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('removing one staged image leaves the other and sends nothing', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();
    imagePicker.result = PickedImage(bytes: _tinyPng, extension: 'jpg');
    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('remove_image_button_0')));
    await tester.pump();

    expect(find.byKey(const ValueKey('remove_image_button_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('remove_image_button_1')), findsNothing);
    expect(runner.uploads, isEmpty);
    expect(runner.commands.any((c) => c.contains("'agent' 'send'")), isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling the image picker stages nothing', (tester) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);
    final imagePicker = FakeImagePicker()..result = null;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          imagePicker: imagePicker,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('attach_image_button')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('remove_image_button_0')), findsNothing);
    expect(runner.uploads, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pulling down at the top loads more transcript lines', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains("'agent' 'read'") && c.contains("'120'"),
      ),
      isTrue,
    );

    // The transcript starts scrolled to the bottom (the live tail). Scroll it
    // to the top first (a separate gesture), then pull further down to
    // trigger the pull-to-load-more.
    await tester.drag(
      find.byKey(const ValueKey('transcript_scroll')),
      const Offset(0, 1000),
    );
    await tester.pump();

    await tester.fling(
      find.byKey(const ValueKey('transcript_scroll')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(
      runner.commands.any(
        (c) => c.contains("'agent' 'read'") && c.contains("'360'"),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pulling down with native history pages older entries in order, and '
    'no-ops (no pane fallback) once the beginning is reached',
    (tester) async {
      final runner = StubCommandRunner(workingResponse);
      final client = HerdrClient(runner);
      // All entries use the user speaker so they render as plain
      // (non-Markdown) bubbles, findable via `find.text` directly.
      final recent = List.generate(
        6,
        (i) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Recent turn $i, with enough filler text to give this row '
              'real height in the transcript list.',
        ),
      );
      final olderChunk1 = List.generate(
        6,
        (i) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Older-1 turn $i, with enough filler text to give this row '
              'real height in the transcript list.',
        ),
      );
      const oldestMessage = TranscriptMessage(
        speaker: TranscriptSpeaker.user,
        text: 'Oldest turn — the very beginning of history.',
      );
      final adapter = _PagedNativeAdapter(NativeTranscript(recent))
        ..olderChunks.addAll([
          olderChunk1,
          [oldestMessage],
        ]);
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The lazy list starts at the live bottom, so only the recent tail is
      // built until the pull gesture moves it toward the older edge.
      expect(find.textContaining('Recent turn 5'), findsOneWidget);
      expect(find.textContaining('Older-1 turn 0'), findsNothing);

      Future<void> pullToLoadMore() async {
        await tester.drag(
          find.byKey(const ValueKey('transcript_scroll')),
          const Offset(0, 1000),
        );
        await tester.pump();
        await tester.fling(
          find.byKey(const ValueKey('transcript_scroll')),
          const Offset(0, 300),
          1000,
        );
        await tester.pumpAndSettle();
      }

      // First pull: dispatches to the native adapter's `loadOlder` (not the
      // pane load-more fallback) and prepends the first older chunk above
      // the recent entries. The restored anchor keeps the prior oldest
      // visible item in place; then scrolling reaches the just-prepended page.
      await pullToLoadMore();
      expect(adapter.loadOlderCalls, 1);
      expect(find.textContaining('Recent turn 0'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 100000),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Older-1 turn 0'), findsOneWidget);

      // Second pull: pages in the final (oldest) chunk and reaches the
      // beginning of the native history.
      await pullToLoadMore();
      expect(adapter.loadOlderCalls, 2);
      await tester.drag(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 100000),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('the very beginning of history'),
        findsOneWidget,
      );
      expect(adapter.hasOlderHistory, isFalse);

      // A further pull is a no-op: no more loadOlder calls, and — since
      // native entries are present — no pane load-more fallback either.
      final paneReadCallsBefore = runner.commands
          .where((c) => c.contains("'agent' 'read'"))
          .length;
      await pullToLoadMore();
      expect(adapter.loadOlderCalls, 2);
      expect(
        runner.commands.where((c) => c.contains("'agent' 'read'")).length,
        paneReadCallsBefore,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a pull-to-load-more that lands while a native poll is still in flight '
    'waits for it instead of being dropped, then pages older entries in '
    'without a second gesture',
    (tester) async {
      final runner = StubCommandRunner(workingResponse);
      final client = HerdrClient(runner);
      final recent = List.generate(
        6,
        (i) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Recent turn $i, with enough filler text to give this row '
              'real height in the transcript list.',
        ),
      );
      final olderChunk = List.generate(
        6,
        (i) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Older turn $i, with enough filler text to give this row '
              'real height in the transcript list.',
        ),
      );
      final adapter = _GatedNativeAdapter(NativeTranscript(recent))
        ..olderChunks.add(olderChunk);
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(seconds: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapter.loadCalls, 1);

      // Hold the *next* native load (a poll tick) mid-flight, simulating a
      // slow read racing a truncation-triggered reset.
      adapter.pendingLoad = Completer<void>();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(adapter.loadCalls, 2);

      Future<void> pumpFrames([int steps = 20]) async {
        for (var i = 0; i < steps; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> pullToLoadMore() async {
        await tester.drag(
          find.byKey(const ValueKey('transcript_scroll')),
          const Offset(0, 1000),
        );
        await tester.pump();
        await tester.fling(
          find.byKey(const ValueKey('transcript_scroll')),
          const Offset(0, 300),
          1000,
        );
        await pumpFrames();
      }

      // A pull-to-load-more gesture landing now must not call into the
      // adapter's `loadOlder` while that poll is still awaiting its gate (the
      // shared single-flight guard in `AgentScreen`), but it must not be
      // dropped either: it waits. `pumpAndSettle` is unusable while the
      // gesture is held — `RefreshIndicator` keeps its spinner animating
      // until `onRefresh` completes — so drive a fixed number of frames.
      await pullToLoadMore();
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      expect(adapter.loadOlderCalls, 0);
      expect(adapter.concurrentAccessDetected, isFalse);

      // Release the poll: the waiting gesture takes the guard and pages the
      // older chunk in on its own, with no second pull from the user and
      // without ever having overlapped the poll.
      adapter.pendingLoad!.complete();
      await pumpFrames();
      expect(adapter.loadOlderCalls, 1);
      expect(adapter.concurrentAccessDetected, isFalse);

      await tester.drag(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 100000),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Older turn 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a pull-to-load-more waiting on an in-flight native poll gives up when '
    'the screen is disposed mid-wait',
    (tester) async {
      final runner = StubCommandRunner(workingResponse);
      final client = HerdrClient(runner);
      final recent = List.generate(
        6,
        (i) => TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text:
              'Recent turn $i, with enough filler text to give this row '
              'real height in the transcript list.',
        ),
      );
      final adapter = _GatedNativeAdapter(NativeTranscript(recent))
        ..olderChunks.add([
          const TranscriptMessage(
            speaker: TranscriptSpeaker.user,
            text: 'Older turn — should never be loaded after disposal.',
          ),
        ]);
      final history = NativeTranscriptHistory(
        runner,
        resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(seconds: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      adapter.pendingLoad = Completer<void>();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(adapter.loadCalls, 2);

      Future<void> pumpFrames([int steps = 20]) async {
        for (var i = 0; i < steps; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.drag(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 1000),
      );
      await tester.pump();
      await tester.fling(
        find.byKey(const ValueKey('transcript_scroll')),
        const Offset(0, 300),
        1000,
      );
      await pumpFrames();
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      expect(adapter.loadOlderCalls, 0);

      // Tearing the screen down while the gesture is still waiting must end
      // the wait, not resume into a read (and a setState) on a dead State.
      await tester.pumpWidget(const SizedBox());
      adapter.pendingLoad!.complete();
      await tester.pumpAndSettle();
      expect(adapter.loadOlderCalls, 0);
    },
  );

  testWidgets('auto-presents the AskUserQuestion sheet when one is pending', (
    tester,
  ) async {
    final runner = NativeHistoryRunner()..contents = askUserTranscriptJsonl;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: HerdrClient(runner),
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StructuredPromptSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StructuredPromptSheet),
        matching: find.text('Which environment should I deploy to?'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('auto-dismisses the sheet once the pending prompt is gone', (
    tester,
  ) async {
    // A tool_result matching the AskUserQuestion's id marks it answered, so the
    // next poll finds no pending prompt.
    const answered =
        '{"type":"user","message":{"role":"user","content":['
        '{"type":"tool_result","tool_use_id":"toolu_askuser_preview"}]}}\n';
    final runner = NativeHistoryRunner()..contents = askUserTranscriptJsonl;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: HerdrClient(runner),
          paneId: 'wB:p1',
          pollInterval: const Duration(seconds: 1),
        ),
      ),
    );
    // Drive the initial load and let the modal animate in (avoiding
    // pumpAndSettle, which never settles against the periodic poll).
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(StructuredPromptSheet), findsOneWidget);

    runner.contents = '$askUserTranscriptJsonl$answered';
    await tester.pump(const Duration(seconds: 1)); // fire the poll timer
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(StructuredPromptSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a poll after a successful submit does not double-pop or toast', (
    tester,
  ) async {
    // A short poll interval so a poll can be fired while the sheet's own close
    // animation (~250ms) is still running — the mid-close race window.
    final runner = AskUserSubmitRunner();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: HerdrClient(runner),
          paneId: 'wB:p1',
          pollInterval: const Duration(milliseconds: 50),
        ),
      ),
    );
    // Drive the initial load and let the sheet animate in.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(StructuredPromptSheet), findsOneWidget);

    // Answer the single question and submit; the real submitter succeeds against
    // the runner's canned reads, clears _askUserSheetOpen, and the sheet starts
    // popping itself. Answer the prompt in the JSONL at the same moment so the
    // very next poll (still mid-close animation) sees no pending prompt — the
    // race window that used to trigger a spurious auto-dismiss (2nd pop + toast).
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt0')));
    await tester.pump();
    runner.contents = '$_singleAskUserJsonl$_singleAskUserAnswered';
    await tester.tap(
      find.byKey(const ValueKey('structured_prompt_send_button')),
    );
    await tester.pump(); // submit resolves; self-pop begins (animation at 0)
    // Fire a poll a single short step in — well within the ~250ms close
    // animation, so the sheet route is still mid-transition.
    await tester.pump(const Duration(milliseconds: 50));
    // Let everything settle out.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The sheet closed exactly once via its own submit; no second pop took the
    // AgentScreen with it, and no "dismissed" toast fired.
    expect(find.byType(AgentScreen), findsOneWidget);
    expect(find.byType(StructuredPromptSheet), findsNothing);
    expect(
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(AgentScreen)),
        )!.agentAskUserDismissed,
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an unsupported agent hides image-attach and mode-cycle controls even '
    'with Claude-like mode text in the pane',
    (tester) async {
      final client = HerdrClient(
        StubCommandRunner(unsupportedAgentModeResponse),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The screen renders normally...
      expect(find.text('mystery · Project B'), findsOneWidget);
      // ...but no adapter supports "mystery", so neither optional capability is
      // resolved and neither control renders, regardless of the pane text
      // containing Claude's own mode-line wording (`idleWithModeText`).
      expect(find.byKey(const ValueKey('attach_image_button')), findsNothing);
      expect(find.byKey(const ValueKey('cycle_mode_button')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an unsupported agent still renders and falls back to the generic '
    'numbered prompt when blocked',
    (tester) async {
      final runner = StubCommandRunner(unsupportedAgentBlockedResponse);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The generic numbered-prompt fallback (parsed straight from pane
      // text) still renders for an agent with no adapter at all.
      expect(find.widgetWithText(FilledButton, 'Yes'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'No'), findsOneWidget);
      expect(find.text('mystery · Project B'), findsOneWidget);
      // Still no mode/image controls, matching an unsupported agent.
      expect(find.byKey(const ValueKey('attach_image_button')), findsNothing);
      expect(find.byKey(const ValueKey('cycle_mode_button')), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Yes'));
      await tester.pump();
      await tester.pump();

      expect(
        runner.commands.any(
          (c) => c.contains("agent' 'prompt'") && c.contains("'1'"),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('restores the composer draft after leaving and returning', (
    tester,
  ) async {
    final store = AgentDraftStore();

    Widget screen() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
      home: AgentScreen(
        client: HerdrClient(StubCommandRunner(blockedPromptResponse)),
        paneId: 'wB:p1',
        draftStore: store,
        pollInterval: const Duration(hours: 1),
      ),
    );

    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'half typed message');

    // Leave the screen (dispose the route), then return to a fresh instance
    // built with the same paneId and store.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pump();

    expect(find.text('half typed message'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('draftKeyPrefix host-scopes the stored draft key', (
    tester,
  ) async {
    final store = AgentDraftStore();

    Widget screen() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
      home: AgentScreen(
        client: HerdrClient(StubCommandRunner(blockedPromptResponse)),
        paneId: 'wB:p1',
        draftStore: store,
        draftKeyPrefix: 'hostX',
        pollInterval: const Duration(hours: 1),
      ),
    );

    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'host-scoped draft');

    // Leaving the screen persists the draft under the prefixed key — never
    // the bare paneId, which another host's same-named pane would share.
    await tester.pumpWidget(const SizedBox());
    expect(store.read('hostX:wB:p1'), 'host-scoped draft');
    expect(store.read('wB:p1'), isNull);

    // Returning with the same prefix restores from the prefixed key.
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(find.text('host-scoped draft'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clears the stored draft after a successful send', (
    tester,
  ) async {
    final store = AgentDraftStore()..write('wB:p1', 'stale draft');
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          draftStore: store,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The seeded draft is restored into the composer.
    expect(find.text('stale draft'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('send_message_button')));
    await tester.pump();
    await tester.pump();

    // A successful send both empties the composer and drops the stored draft,
    // so a later visit starts blank rather than re-restoring the sent text.
    expect(store.read('wB:p1'), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Copilot plain-text send routes through focus-gained/focus-lost brackets',
    (tester) async {
      CommandResult copilotIdleResponse(String command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}'
            ']}}',
          );
        }
        if (command.contains("'agent' 'list'")) {
          return ok(
            '{"id":"1","result":{"agents":[{"agent":"copilot",'
            '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
            '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
            '"name":"Copilot Agent"}]}}',
          );
        }
        if (command.contains("'agent' 'read'")) {
          return ok('Copilot idle');
        }
        return ok('{"id":"1","result":{}}');
      }

      final runner = StubCommandRunner(copilotIdleResponse);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello copilot');
      await tester.tap(find.byKey(const ValueKey('send_message_button')));
      await tester.pump();
      await tester.pump();

      final promptIdx = runner.commands.indexWhere(
        (c) => c.contains("'agent' 'prompt'"),
      );
      expect(promptIdx, isNot(-1), reason: 'prompt command must be present');
      expect(
        runner.commands[promptIdx - 1],
        contains('\x1b[I'),
        reason: 'focus-gained must precede the prompt',
      );
      expect(
        runner.commands[promptIdx + 1],
        contains('\x1b[O'),
        reason: 'focus-lost must follow the prompt',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Copilot image send routes through focus-gained/focus-lost brackets',
    (tester) async {
      CommandResult copilotIdleResponse(String command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}'
            ']}}',
          );
        }
        if (command.contains("'agent' 'list'")) {
          return ok(
            '{"id":"1","result":{"agents":[{"agent":"copilot",'
            '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
            '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
            '"name":"Copilot Agent"}]}}',
          );
        }
        if (command.contains("'agent' 'read'")) {
          return ok('Copilot idle');
        }
        return ok('{"id":"1","result":{}}');
      }

      final runner = StubCommandRunner(copilotIdleResponse);
      final client = HerdrClient(runner);
      final imagePicker = FakeImagePicker();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            imagePicker: imagePicker,
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Stage an image and send it.
      await tester.tap(find.byKey(const ValueKey('attach_image_button')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send_message_button')));
      await tester.pump();
      await tester.pump();

      final promptIdx = runner.commands.indexWhere(
        (c) => c.contains("'agent' 'prompt'"),
      );
      expect(promptIdx, isNot(-1), reason: 'image prompt command must be sent');
      expect(
        runner.commands[promptIdx - 1],
        contains('\x1b[I'),
        reason: 'focus-gained must precede the image prompt',
      );
      expect(
        runner.commands[promptIdx + 1],
        contains('\x1b[O'),
        reason: 'focus-lost must follow the image prompt',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('hides the switcher bar with a single agent', (tester) async {
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('switcher_herd_tab')), findsNothing);
    expect(find.byIcon(Icons.grid_view), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the switcher bar with two or more agents', (tester) async {
    final client = HerdrClient(StubCommandRunner(multiAgentResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('switcher_herd_tab')), findsOneWidget);
    expect(find.byKey(const ValueKey('switcher_agent_wB:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('switcher_agent_wA:p1')), findsOneWidget);

    // The current agent (wB:p1) is ringed in the accent colour; another agent
    // (wA:p1) carries a transparent border of the same width.
    Border ringOf(String paneId) {
      final container = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(ValueKey('switcher_agent_$paneId')),
              matching: find.byType(Container),
            ),
          )
          .firstWhere((c) => c.foregroundDecoration is BoxDecoration);
      return (container.foregroundDecoration as BoxDecoration).border as Border;
    }

    expect(ringOf('wB:p1').top.color, DroverColors.dark.accentText);
    expect(ringOf('wA:p1').top.color, Colors.transparent);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'seeds the switcher bar from initialAgents on the first frame, before '
    'any listAgents poll lands (a bar switch must not collapse and re-enter)',
    (tester) async {
      final client = HerdrClient(StubCommandRunner(multiAgentResponse));
      const current = AgentInfo(
        paneId: 'wB:p1',
        workspaceId: 'wB',
        tabId: 'wB:t1',
        agent: 'claude',
        status: AgentStatus.working,
        cwd: '/tmp/proj-b',
        focused: false,
      );
      const other = AgentInfo(
        paneId: 'wA:p1',
        workspaceId: 'wA',
        tabId: 'wA:t1',
        agent: 'codex',
        status: AgentStatus.idle,
        cwd: '/tmp/proj-a',
        focused: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            initialAgent: current,
            initialAgents: const [current, other],
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );

      // Deliberately no extra pump/settle: the very first frame must already
      // show the fully-entered bar (its entrance controller starts at 1 when
      // the seeded list has >= 2 agents), keys absent only when hidden.
      expect(find.byKey(const ValueKey('switcher_herd_tab')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('switcher_agent_wA:p1')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shortens a long bar label to six characters plus an ellipsis', (
    tester,
  ) async {
    final client = HerdrClient(StubCommandRunner(multiAgentResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // "Database" is 8 chars (> 7): first 6 + '…'. "Alpha" (5) stays whole.
    // Bar labels keep their own casing — they are user-chosen session titles,
    // so the current agent's cell now matches its header title verbatim and
    // has to be scoped to the cell.
    expect(find.text('Databa…'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('switcher_agent_wB:p1')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'tapping the current agent is a no-op; tapping another replaces the route',
    (tester) async {
      final client = HerdrClient(StubCommandRunner(multiAgentResponse));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('claude · Project B'), findsOneWidget);

      // Current agent → no-op: still on wB:p1.
      await tester.tap(find.byKey(const ValueKey('switcher_agent_wB:p1')));
      await tester.pumpAndSettle();
      expect(find.text('claude · Project B'), findsOneWidget);

      // Another agent → the route is replaced with its screen.
      await tester.tap(find.byKey(const ValueKey('switcher_agent_wA:p1')));
      await tester.pumpAndSettle();
      expect(find.byType(AgentScreen), findsOneWidget);
      expect(find.text('Database'), findsOneWidget);
      expect(find.textContaining('codex ·'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the herd tab pops to the first route', (tester) async {
    final client = HerdrClient(StubCommandRunner(multiAgentResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AgentScreen(
                      client: client,
                      paneId: 'wB:p1',
                      pollInterval: const Duration(hours: 1),
                    ),
                  ),
                ),
                child: const Text('open agent'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open agent'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('switcher_herd_tab')));
    await tester.pumpAndSettle();
    expect(find.byType(AgentScreen), findsNothing);
    expect(find.text('open agent'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders prompt-card option labels without the number prefix', (
    tester,
  ) async {
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Yes'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'No'), findsOneWidget);
    // No option button carries the leading "N. " numbering.
    expect(find.widgetWithText(FilledButton, '1. Yes'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reveals four arrow buttons on toggle, each sending its herdr key token',
    (tester) async {
      final runner = StubCommandRunner(blockedPromptResponse);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            draftStore: AgentDraftStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The row is collapsed by default: the toggle is the only new affordance.
      expect(
        find.byKey(const ValueKey('toggle_arrow_keys_button')),
        findsOneWidget,
      );
      for (final key in ['left', 'up', 'down', 'right']) {
        expect(find.byKey(ValueKey('send_key_$key')), findsNothing);
      }

      await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
      await tester.pumpAndSettle();

      for (final key in ['left', 'up', 'down', 'right']) {
        expect(find.byKey(ValueKey('send_key_$key')), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('send_key_down')));
      await tester.pump();
      await tester.pump();

      expect(
        runner.commands.any(
          (c) => c.contains('send-keys') && c.contains("'down'"),
        ),
        isTrue,
      );

      // Tapping the toggle again puts the row away.
      await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('send_key_down')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reveals Esc and Enter in the same collapsible key row', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
          draftStore: AgentDraftStore(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Collapsed by default: Esc and Enter ride the key row, not the button row.
    expect(find.byKey(const ValueKey('send_escape_button')), findsNothing);
    expect(find.byKey(const ValueKey('send_enter_button')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('send_escape_button')), findsOneWidget);
    expect(find.byKey(const ValueKey('send_enter_button')), findsOneWidget);

    // And they go away again with the arrows.
    await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('send_escape_button')), findsNothing);
    expect(find.byKey(const ValueKey('send_enter_button')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'keeps the arrow keys live while a send is in flight, and sends them in '
    'tap order',
    (tester) async {
      final runner = ArrowKeyRunner();
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            draftStore: AgentDraftStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
      await tester.pumpAndSettle();

      // Start a send that never completes: Esc goes through `_send`, so the
      // composer's own buttons go dead for its whole round-trip.
      await tester.tap(find.byKey(const ValueKey('send_escape_button')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('send_escape_button')),
            )
            .onPressed,
        isNull,
      );

      // The arrows are unaffected: three rapid taps all land.
      await tester.tap(find.byKey(const ValueKey('send_key_down')));
      await tester.tap(find.byKey(const ValueKey('send_key_down')));
      await tester.tap(find.byKey(const ValueKey('send_key_right')));
      // Plain pumps, not pumpAndSettle: the in-flight send spins the send
      // button's progress indicator, which never settles.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      // 'down' is the slow one, so this order is only reachable if the sends
      // are queued rather than fired off in parallel.
      expect(runner.arrowsCompleted, ['down', 'down', 'right']);

      // A failing key must surface, and must not poison the queue for the
      // ones behind it.
      await tester.tap(find.byKey(const ValueKey('send_key_left')));
      await tester.tap(find.byKey(const ValueKey('send_key_up')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('arrow key rejected'), findsOneWidget);
      expect(runner.arrowsCompleted.last, 'up');

      runner.escGate.complete();
      await tester.pump();
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shows the live terminal once an arrow key is sent from this screen, '
    'even for pane text the native transcript would otherwise hide as '
    'duplicate',
    (tester) async {
      final client = HerdrClient(DuplicatePaneRunner());

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            draftStore: AgentDraftStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Every pane line is already in the native conversation, so the section
      // is suppressed as redundant.
      expect(find.text('LIVE TERMINAL'), findsNothing);

      // Merely opening the row is not enough: the flag behind it is
      // process-global, so a screen the user never drove keeps its dedup.
      await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
      await tester.pumpAndSettle();
      expect(find.text('LIVE TERMINAL'), findsNothing);

      // Actually pressing an arrow means a TUI overlay is being driven from
      // here and the raw pane has to be watchable, so the dedup is bypassed.
      await tester.tap(find.byKey(const ValueKey('send_key_down')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('LIVE TERMINAL'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('keeps the arrow-key row open across a rebuild of the screen', (
    tester,
  ) async {
    final client = HerdrClient(StubCommandRunner(blockedPromptResponse));
    final store = AgentDraftStore();

    Widget screen() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
      home: AgentScreen(
        client: client,
        paneId: 'wB:p1',
        pollInterval: const Duration(hours: 1),
        draftStore: store,
      ),
    );

    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('toggle_arrow_keys_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('send_key_down')), findsOneWidget);

    // Popping and re-pushing the route disposes the State; the store outlives
    // it, so the row comes back open.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('send_key_down')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('composer button row never overflows on a narrow phone', (
    tester,
  ) async {
    // The narrowest phone drover targets (iPhone SE / 13 mini logical size).
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = HerdrClient(StubCommandRunner(acceptEditsModeResponse));
    final store = AgentDraftStore()..keysRowOpen = true;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
          draftStore: store,
          imagePicker: FakeImagePicker(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Everything the composer can hold at once: attach and the widest mode
    // pill beside the arrow-key toggle, mic and send — plus the open key row
    // carrying the four arrows, Esc and Enter.
    expect(find.byKey(const ValueKey('attach_image_button')), findsOneWidget);
    expect(find.text('Accept Edits'), findsOneWidget);

    // `find.byKey` also matches widgets clipped out of the viewport, so these
    // must be asserted as reachable and on-screen: the toggle is the
    // feature's only entry point, and send is the composer's primary action.
    for (final key in [
      'toggle_arrow_keys_button',
      'dictate_button',
      'send_message_button',
      'send_key_left',
      'send_key_up',
      'send_key_down',
      'send_key_right',
      'send_escape_button',
      'send_enter_button',
    ]) {
      final finder = find.byKey(ValueKey(key));
      expect(finder.hitTestable(), findsOneWidget, reason: key);
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0.0), reason: key);
      expect(rect.right, lessThanOrEqualTo(375.0), reason: key);
    }

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'the two fixed-dark machine surfaces each carry their spec hairline',
    (tester) async {
      final runner = NativeHistoryRunner();
      // An assistant turn with a fenced block, so the code panel renders in
      // the same frame as the live terminal.
      runner.contents =
          '{"type":"user","message":{"role":"user","content":"q"}}\n'
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"text","text":"reply\\n\\n```\\nplain code\\n```"}]}}\n';
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      BoxDecoration panelFilled(Color fill) => tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere(
            (d) => d.color == fill,
            orElse: () => throw TestFailure('no panel filled $fill'),
          );

      // Both panels stay fixed-dark in either theme, so against the ink page
      // the hairline is the only thing separating them from their ground —
      // losing it makes them disappear rather than merely look flatter.
      final terminal = panelFilled(const Color(0xFF1A1D22)).border! as Border;
      expect(terminal.top.color, const Color(0xFF2B3038));
      expect(terminal.top.width, 1);
      expect(terminal.isUniform, isTrue);

      final code = panelFilled(const Color(0xFF26262B)).border! as Border;
      expect(code.top.color, const Color(0xFF35353D));
      expect(code.top.width, 1);
      expect(code.isUniform, isTrue);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the rounded shape vocabulary holds in the built tree', (
    tester,
  ) async {
    // Every button paints through a Material whose `shape` is the *resolved*
    // one, so reading it here covers both the shapes agent_screen declares and
    // the ones it now inherits from Material's own M3 defaults.
    OutlinedBorder resolvedShape(Finder control, String reason) {
      final shapes = tester
          .widgetList<Material>(
            find.descendant(of: control, matching: find.byType(Material)),
          )
          .map((m) => m.shape)
          .whereType<OutlinedBorder>()
          .toList();
      expect(shapes, isNotEmpty, reason: reason);
      return shapes.first;
    }

    // Circles and stadiums are the vocabulary now, so the guard is the other
    // way round: nothing may paint a corner tighter than the smallest step.
    // That is what an angular scale creeping back in would look like.
    //
    // Buttons carry their radius on `Material.shape`, but every panel on this
    // screen — composer, transcript, prompt card, the code and diff blocks,
    // the user bubble — paints it through a `BoxDecoration` instead, so
    // reading only the Materials would leave all of them unguarded.
    void expectNoTightCorners() {
      final radii = <BorderRadius>[];
      for (final material in tester.widgetList<Material>(
        find.byType(Material),
      )) {
        final shape = material.shape;
        if (shape is RoundedRectangleBorder) {
          radii.add(shape.borderRadius.resolve(TextDirection.ltr));
        }
      }
      // Container builds a DecoratedBox for `decoration` and another for
      // `foregroundDecoration`, so this covers both.
      for (final box in tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      )) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration) {
          final radius = decoration.borderRadius;
          if (radius != null) radii.add(radius.resolve(TextDirection.ltr));
        } else if (decoration is ShapeDecoration) {
          final shape = decoration.shape;
          if (shape is RoundedRectangleBorder) {
            radii.add(shape.borderRadius.resolve(TextDirection.ltr));
          }
        }
      }
      expect(radii, isNotEmpty, reason: 'the sweep inspected nothing');
      for (final r in radii) {
        for (final corner in [
          r.topLeft,
          r.topRight,
          r.bottomLeft,
          r.bottomRight,
        ]) {
          expect(
            corner.x,
            greaterThanOrEqualTo(droverRadiusSmall),
            reason: 'corner $corner is tighter than droverRadiusSmall',
          );
        }
      }
    }

    Future<void> pump(CommandResult Function(String) response) async {
      final client = HerdrClient(StubCommandRunner(response));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            draftStore: AgentDraftStore()..keysRowOpen = true,
            imagePicker: FakeImagePicker(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    // The composer at its fullest: attach + mode chip + the open key row.
    await pump(acceptEditsModeResponse);
    expectNoTightCorners();

    // Every icon button on this screen is a circle. None of these can be left
    // to the theme: M3's default for IconButton, OutlinedButton and
    // FilledButton alike is a stadium, which only *looks* circular because
    // these all sit in square footprints.
    for (final key in [
      'agent_back_button',
      'attach_image_button',
      'dictate_button',
      'send_message_button',
      'toggle_arrow_keys_button',
      'send_key_left',
      'send_key_up',
      'send_key_down',
      'send_key_right',
      'send_escape_button',
      'send_enter_button',
    ]) {
      expect(
        resolvedShape(find.byKey(ValueKey(key)), key),
        isA<CircleBorder>(),
        reason: key,
      );
    }

    // The mode chip is the rounded rect in the pair — deliberately not a
    // pill, so it cannot be mistaken for a status chip.
    final modeShape = resolvedShape(
      find.byKey(const ValueKey('cycle_mode_button')),
      'mode',
    );
    expect(modeShape, isNot(isA<StadiumBorder>()));
    expect(modeShape, isA<RoundedRectangleBorder>());

    await tester.pumpWidget(const SizedBox());

    // The blocked state adds the prompt card's answer rows.
    await pump(blockedPromptResponse);
    expectNoTightCorners();

    // The answer rows are the one control here that is deliberately not a
    // pill: they stay full-width at 44px, where M3's stadium reads wrong. That
    // shape has to be pinned, so a dropped `shape:` would silently restore it.
    final rows = find.byWidgetPredicate(
      (w) =>
          w is FilledButton && w.key != const ValueKey('send_message_button'),
    );
    expect(rows, findsWidgets);
    for (var i = 0; i < rows.evaluate().length; i++) {
      final shape = resolvedShape(rows.at(i), 'answer row $i');
      expect(shape, isNot(isA<StadiumBorder>()), reason: 'answer row $i');
      expect(shape, isA<RoundedRectangleBorder>(), reason: 'answer row $i');
      expect(
        (shape as RoundedRectangleBorder).borderRadius
            .resolve(TextDirection.ltr)
            .topLeft
            .x,
        droverRadiusMedium,
        reason: 'answer row $i',
      );
      expect(tester.getSize(rows.at(i)).height, greaterThanOrEqualTo(44.0));
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the mode chip carries its colour as a left rule, not a fill', (
    tester,
  ) async {
    // Both themes: the bug this guards against was invisible in dark and only
    // bit on the light composer ground.
    Future<void> checkIn(ThemeData theme, String label) async {
      final client = HerdrClient(StubCommandRunner(acceptEditsModeResponse));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final chip = find.byKey(const ValueKey('cycle_mode_button'));
      final decoration = tester
          .widgetList<DecoratedBox>(
            find.ancestor(of: chip, matching: find.byType(DecoratedBox)),
          )
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.border != null);
      final border = decoration.border! as Border;

      // A chip *filled* in a mode colour reads as a status, and one *lettered*
      // in it is unreadable on a wash of itself. The colour stays on the edge
      // and the label stays neutral.
      expect(border.left.color, modeAcceptEdit, reason: label);
      expect(border.left.width, 2, reason: label);
      expect(border.top, BorderSide.none, reason: label);
      expect(border.right, BorderSide.none, reason: label);
      final fill = decoration.color;
      expect(fill, theme.colorScheme.surfaceContainerHigh, reason: label);
      expect(fill, isNot(modeAcceptEdit), reason: label);

      // The assertion that would have caught the regression: whatever colour
      // the label ends up in has to be legible on the fill behind it. 12.5px
      // w700 is normal-size text, so AA is 4.5:1.
      final labelColor = tester
          .widget<OutlinedButton>(chip)
          .style!
          .foregroundColor!
          .resolve({})!;
      // computeLuminance() ignores alpha, so a translucent fill would be
      // scored as its full-strength hue — a colour that never reaches the
      // screen. The tint this test guards against is exactly that, so the
      // ratio is only meaningful once the fill is known opaque.
      expect(
        fill!.a,
        1.0,
        reason: '$label: contrast is only meaningful on an opaque fill',
      );
      expect(
        _contrastRatio(labelColor, fill),
        greaterThanOrEqualTo(4.5),
        reason: '$label: mode label on its own fill',
      );
      expect(labelColor, theme.colorScheme.onSurface, reason: label);

      // What keeps a mode chip apart from a status pill on top of the shape:
      // a status pill always carries a dot, a mode chip never does.
      expect(
        tester
            .widgetList<Container>(
              find.descendant(of: chip, matching: find.byType(Container)),
            )
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .where((d) => d.shape == BoxShape.circle),
        isEmpty,
        reason: label,
      );

      await tester.pumpWidget(const SizedBox());
    }

    await checkIn(droverDarkTheme, 'dark');
    await checkIn(droverLightTheme, 'light');
  });

  testWidgets('the label ramp does not uppercase under a Japanese locale', (
    tester,
  ) async {
    final runner = StubCommandRunner(workingResponse);
    final adapter = _PagedNativeAdapter(
      NativeTranscript(const [
        TranscriptMessage(
          speaker: TranscriptSpeaker.assistant,
          text: 'A native turn',
        ),
      ]),
    );

    Future<void> pumpIn(String locale) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: droverDarkTheme.copyWith(platform: defaultTargetPlatform),
          home: AgentScreen(
            client: HerdrClient(runner),
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            nativeTranscriptHistory: NativeTranscriptHistory(
              runner,
              resolveAdapter: (agent) => _FixedNativeHistoryAdapter(adapter),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // The transcript section captions are fixed localized strings — the ramp
    // is for those, not for the user-chosen names (workspace label, agent
    // name) that are deliberately off it.
    await pumpIn('en');
    expect(find.text('CONVERSATION HISTORY'), findsOneWidget);
    expect(find.text('Conversation history'), findsNothing);
    expect(find.text('LIVE TERMINAL'), findsOneWidget);

    // Uppercase is a Latin device: full-width glyphs have no case, and the
    // tracking that makes caps legible collides them.
    await pumpIn('ja');
    expect(find.text('会話履歴'), findsOneWidget);
    expect(find.text('ライブターミナル'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}

/// WCAG 2.1 relative-contrast ratio. Both colours must be opaque:
/// `computeLuminance()` ignores alpha, so callers assert that themselves.
double _contrastRatio(Color fg, Color bg) {
  final a = fg.computeLuminance();
  final b = bg.computeLuminance();
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}
