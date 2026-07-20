import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/dev/stub_herdr.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/image/image_input.dart';
import 'package:drover/src/screens/agent_screen.dart';
import 'package:drover/src/speech/speech_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A valid 1x1 PNG so the composer's `Image.memory` preview can decode it in
/// widget tests (arbitrary bytes would throw during paint).
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class FakeImagePicker implements ImagePickerPort {
  FakeImagePicker({PickedImage? result})
    : result = result ?? PickedImage(bytes: _tinyPng, extension: 'png');

  PickedImage? result;
  final sources = <ImageAttachSource>[];

  @override
  Future<PickedImage?> pickImage(ImageAttachSource source) async {
    sources.add(source);
    return result;
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

void main() {
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
}
