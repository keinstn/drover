import 'dart:async';
import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/agents/agent_adapter.dart';
import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/agent_native_history.dart';
import 'package:drover/src/dev/stub_herdr.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
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
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"claude",'
      '"agent_status":"working","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok('{"id":"1","result":{"read":{"text":"working…"}}}');
  }
  return ok('{"id":"1","result":{}}');
}

/// An unrecognized agent ("codex", say) whose pane happens to contain
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
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"codex",'
      '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${jsonEncode(idleWithModeText)}}}}',
    );
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
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"codex",'
      '"agent_status":"blocked","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${jsonEncode(blockedPromptText)}}}}',
    );
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
    if (command.contains("'agent' 'get'")) {
      return ok(
        '{"id":"1","result":{"agent":{"agent":"claude",'
        '"agent_status":"working","cwd":"/tmp/proj","focused":false,'
        '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
        '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
        '"value":"c7c50b87-4d4c-4a92-9396-2cfa4158612d"}}}}',
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
    if (command.contains("'agent' 'get'")) {
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
      return ok(
        '{"id":"1","result":{"read":{"text":'
        '"Native question\\nNative reply\\n"}}}',
      );
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
      return ok('{"id":"1","result":{"read":{"text":${jsonEncode(text)}}}}');
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

void main() {
  // Tests that don't inject their own store fall back to AgentDraftStore.shared,
  // and any draft a test types is persisted there on dispose. Reset the shared
  // draft for the common paneId before each test so that leak never carries a
  // stale draft into a later test's composer.
  setUp(() => AgentDraftStore.shared.clear('wB:p1'));

  testWidgets('renders native Claude history with a separated live terminal', (
    tester,
  ) async {
    final runner = NativeHistoryRunner();
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
    expect(find.text('Conversation history'), findsOneWidget);
    expect(find.text('Native question'), findsOneWidget);
    // The assistant reply is Markdown-rendered (a RichText, not a Text widget).
    expect(
      find.textContaining('Native reply', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Live terminal'), findsOneWidget);
    expect(find.text('working…'), findsOneWidget);

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
    expect(find.text('Conversation history'), findsNothing);
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
    expect(find.text('Conversation history'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);

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

  testWidgets(
    'hides the live terminal when the pane duplicates native history',
    (tester) async {
      final client = HerdrClient(DuplicatePaneRunner());

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
      expect(find.text('Conversation history'), findsOneWidget);
      expect(find.text('Native question'), findsOneWidget);
      expect(find.text('Live terminal'), findsNothing);

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
    expect(find.text('Conversation history'), findsNothing);

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
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('working…'), findsOneWidget);
    expect(find.textContaining('Native history unavailable'), findsOneWidget);

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
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't load agent"), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transcript_initial_loading')),
        findsNothing,
      );
      expect(find.text('working…'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't load agent"), findsNothing);
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
    expect(find.textContaining('Native history unavailable'), findsOneWidget);

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
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(FilledButton, '1. Yes'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '3. No'), findsOneWidget);
    expect(find.text('blocked · Project B'), findsOneWidget);
    expect(find.textContaining('p1'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '1. Yes'));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains("agent' 'send'") && c.contains("'1'"),
      ),
      isTrue,
    );
    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'enter'"),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps the draft and shows an error when send fails', (
    tester,
  ) async {
    CommandResult respondFailingSend(String command) {
      if (command.contains("'agent' 'send'")) {
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
    // sequence via `pane send-text` (herdr's `send-keys shift+tab` mis-encodes
    // it — see herdr issue #1561).
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

  testWidgets('sends Esc from the always-available escape button when idle', (
    tester,
  ) async {
    final runner = StubCommandRunner(blockedPromptResponse);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
      runner.commands.where((c) => c.contains("'agent' 'send'")).length,
      1,
    );
    expect(
      runner.commands.any(
        (c) =>
            c.contains("'agent' 'send'") &&
            c.contains('.drover') &&
            c.contains('look at this'),
      ),
      isTrue,
    );
    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'enter'"),
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
          home: AgentScreen(
            client: client,
            paneId: 'wB:p1',
            pollInterval: const Duration(hours: 1),
            nativeTranscriptHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Recent turn 0'), findsOneWidget);
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
      // the already-visible recent entries, in order.
      await pullToLoadMore();
      expect(adapter.loadOlderCalls, 1);
      expect(find.textContaining('Older-1 turn 0'), findsOneWidget);
      final olderTop = tester
          .getTopLeft(find.textContaining('Older-1 turn 0'))
          .dy;
      final recentTop = tester
          .getTopLeft(find.textContaining('Recent turn 0'))
          .dy;
      expect(olderTop, lessThan(recentTop));

      // Second pull: pages in the final (oldest) chunk and reaches the
      // beginning of the native history.
      await pullToLoadMore();
      expect(adapter.loadOlderCalls, 2);
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
    'is gated out rather than racing it, and proceeds normally once the '
    'poll completes',
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

      // A pull-to-load-more gesture landing now must not call into the
      // adapter's `loadOlder` while that poll is still awaiting its gate —
      // it should be gated out by the shared `_nativeHistoryLoading` flag
      // (see `AgentScreen._loadOlderNativeHistory`) instead of racing it.
      // `pumpAndSettle` is safe here even with the poll's own load stuck:
      // only that detached `load()` future is pending, and it isn't tied to
      // any animation, so the pull gesture's own frames settle normally.
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

      expect(adapter.loadOlderCalls, 0);
      expect(adapter.concurrentAccessDetected, isFalse);

      // Release the poll; it completes normally, and pull-to-load-more now
      // proceeds (un-gated) without ever having overlapped the poll.
      adapter.pendingLoad!.complete();
      await tester.pumpAndSettle();
      expect(adapter.concurrentAccessDetected, isFalse);

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

      expect(adapter.loadOlderCalls, 1);
      expect(adapter.concurrentAccessDetected, isFalse);
      expect(find.textContaining('Older turn 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
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
      expect(find.text('idle · Project B'), findsOneWidget);
      // ...but no adapter supports "codex", so neither optional capability is
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
      expect(find.widgetWithText(FilledButton, '1. Yes'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '3. No'), findsOneWidget);
      expect(find.text('blocked · Project B'), findsOneWidget);
      // Still no mode/image controls, matching an unsupported agent.
      expect(find.byKey(const ValueKey('attach_image_button')), findsNothing);
      expect(find.byKey(const ValueKey('cycle_mode_button')), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '1. Yes'));
      await tester.pump();
      await tester.pump();

      expect(
        runner.commands.any(
          (c) => c.contains("agent' 'send'") && c.contains("'1'"),
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
}
