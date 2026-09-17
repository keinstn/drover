import 'dart:async';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/voice/voice_drafts.dart';
import 'package:drover/src/voice/voice_herd.dart';
import 'package:drover/src/voice/voice_screen.dart';
import 'package:drover/src/voice/voice_session.dart';
import 'package:drover/src/voice/voice_tools.dart';
import 'package:drover/src/voice/voice_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeTransport transport;
  late FakeMic mic;
  late FakeSpeaker speaker;

  setUp(() {
    transport = FakeTransport();
    mic = FakeMic();
    speaker = FakeSpeaker();
  });

  // A live screen repeats the orb's ticker, so tests must `pump` a live
  // screen, never `pumpAndSettle` it (only an ended session settles).
  Widget app({
    FakeVoiceHerd? herd,
    VoiceInbox? inbox,
    VoiceDrafts? drafts,
    Future<VoiceTransport> Function(String?)? connect,
  }) => MaterialApp(
    theme: droverDarkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: VoiceScreen(
      session: VoiceSession(
        connect: connect ?? (_) async => transport,
        mic: mic,
        speaker: speaker,
        herd: herd,
        inbox: inbox,
        drafts: drafts,
        tools: [
          VoiceTool(
            name: 'list_agents',
            description: '',
            parameters: const {},
            run: (_) async => {'agents': []},
          ),
        ],
      ),
    ),
  );

  /// Toggles the transcript and lets the stage/transcript switch finish.
  Future<void> toggleTranscript(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('voice_transcript_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('starts on open and shows the hint until something is said', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Listening'), findsOneWidget);
    expect(find.textContaining('Ask about your agents'), findsOneWidget);
    expect(find.byTooltip('End'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders assistant text after a completed turn', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    transport.push(
      LiveServerContent(
        outputTranscription: const Transcription(text: 'One agent is blocked.'),
        turnComplete: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Ask about your agents'), findsNothing);
    await toggleTranscript(tester);
    expect(find.text('One agent is blocked.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders the resumed notice after a reconnect', (tester) async {
    final connector = FakeConnector();
    await tester.pumpWidget(app(connect: connector.call));
    await tester.pump();

    connector.last.pushResumption('h1');
    await tester.pump();
    await connector.transports.first.server.close();
    await tester.pump();
    await tester.pump();

    expect(find.text('Reconnected, continuing'), findsOneWidget);
    expect(find.text('Session ended'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders a tool line for a tool call', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    transport.push(
      LiveServerToolCall(
        functionCalls: const [FunctionCall('list_agents', {}, id: 'c1')],
      ),
    );
    await tester.pump();
    await tester.pump();

    await toggleTranscript(tester);
    expect(find.text('Called list_agents'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tapping End renders the ended status and offers Restart', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();

    expect(find.text('Ended'), findsOneWidget);
    expect(find.text('Session ended'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(transport.closeCalls, 1);
    final action = find.byKey(const ValueKey('voice_action_button'));
    expect(action, findsOneWidget);
    expect(
      find.descendant(of: action, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
    expect(find.byTooltip('End'), findsNothing);
    expect(find.byKey(const ValueKey('voice_close_button')), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('Restart clears the previous session\'s end from the stage', (
    tester,
  ) async {
    final connector = FakeConnector();
    await tester.pumpWidget(app(connect: connector.call));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();
    expect(find.text('Session ended'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pump();
    await tester.pump();

    expect(connector.transports, hasLength(2));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('voice_status'))).data,
      'Listening',
    );
    expect(find.text('Session ended'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('offers a labelled Back while live', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Listening'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('several pending cards scroll instead of overflowing', (
    tester,
  ) async {
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      drafts.addLaunch(
        kind: 'codex',
        cwd: '/home/me/proj$i',
        brief:
            'Add a retry to the webhook client. Back off exponentially and '
            'cap it at five attempts. Keep the change small and add a test.',
      );
    }
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    final first = find.byKey(const ValueKey('voice_launch_d1'));
    final last = find.byKey(const ValueKey('voice_launch_d4'));
    expect(first, findsOneWidget);
    expect(last, findsOneWidget);
    await tester.ensureVisible(last);
    await tester.pump();
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(600));
    await tester.ensureVisible(first);
    await tester.pump();
    expect(tester.getRect(first).top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the transcript button swaps the stage for the log and back', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();
    transport.push(
      LiveServerContent(
        outputTranscription: const Transcription(text: 'One agent is blocked.'),
        turnComplete: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    // The stage keeps the last utterance as its caption, so the text is on
    // both faces; what flips is the status label versus the log itself.
    final status = find.byKey(const ValueKey('voice_status'));
    final said = find.text('One agent is blocked.');
    expect(status, findsOneWidget);
    expect(said, findsOneWidget);
    expect(find.byType(ListView), findsNothing);

    await toggleTranscript(tester);
    expect(status, findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    expect(said, findsOneWidget);

    await toggleTranscript(tester);
    expect(status, findsOneWidget);
    expect(find.byType(ListView), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders why the session ended when the cap runs out', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.pump(kVoiceSessionCap + const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Session time limit reached'), findsOneWidget);
    expect(find.text('Ended'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders an announced event as a muted line', (tester) async {
    final herd = FakeVoiceHerd();
    final inbox = VoiceInbox();
    await tester.pumpWidget(app(herd: herd, inbox: inbox));
    await tester.pump();

    inbox.add(AgentEvent(AgentEventKind.finished, fakeAgent(kind: 'claude')));
    await tester.pump();
    await tester.pump();

    await toggleTranscript(tester);
    expect(find.text('claude finished'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    inbox.dispose();
  });

  testWidgets('a pending draft renders with Send; tapping sends it', (
    tester,
  ) async {
    final herd = FakeVoiceHerd();
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: herd, drafts: drafts));
    await tester.pump();

    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting to send to claude'), findsOneWidget);
    expect(find.text('add tests too'), findsOneWidget);
    final send = find.byKey(const ValueKey('voice_draft_send_d1'));
    expect(send, findsOneWidget);

    await tester.tap(send);
    await tester.pump();
    await tester.pump();

    expect(herd.sent.single.$2, 'add tests too');
    expect(send, findsNothing);
    expect(find.text('Waiting to send to claude'), findsNothing);
    await toggleTranscript(tester);
    expect(find.text('Sent to claude'), findsOneWidget);
    expect(find.text('add tests too'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a launch draft renders the brief; tapping Launch starts it', (
    tester,
  ) async {
    final herd = FakeVoiceHerd();
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: herd, drafts: drafts));
    await tester.pump();

    drafts.addLaunch(
      kind: 'codex',
      cwd: '/home/me/billing-api',
      brief: 'Add a retry to the webhook client. Keep it small.',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting to start Codex in billing-api'), findsOneWidget);
    expect(
      find.text('Add a retry to the webhook client. Keep it small.'),
      findsOneWidget,
    );
    final launch = find.byKey(const ValueKey('voice_launch_d1'));
    expect(launch, findsOneWidget);

    // The launch takes a while; the button must not start a second agent.
    herd.launchGate = Completer<void>();
    await tester.tap(launch);
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(launch).onPressed, isNull);
    await tester.tap(launch, warnIfMissed: false);
    await tester.pump();

    herd.launchGate!.complete();
    await tester.pump();
    await tester.pump();

    expect(herd.launched.single, (
      'codex',
      '/home/me/billing-api',
      'Add a retry to the webhook client. Keep it small.',
    ));
    expect(launch, findsNothing);
    await toggleTranscript(tester);
    expect(find.text('Started Codex in billing-api'), findsOneWidget);
    expect(find.text('Codex in billing-api'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('ending with a pending draft shows the unsent notice', (
    tester,
  ) async {
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
    await tester.pump();
    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    drafts.addLaunch(kind: 'codex', cwd: '/tmp/proj', brief: 'add retries');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();

    // Worded for either card: a launch draft's button says Launch, not Send.
    expect(
      find.text(
        'A draft is still pending — the button on its card still works',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_draft_send_d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice_launch_d2')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
