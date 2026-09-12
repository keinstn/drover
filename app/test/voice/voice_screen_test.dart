import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/voice/voice_screen.dart';
import 'package:drover/src/voice/voice_session.dart';
import 'package:drover/src/voice/voice_tools.dart';
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

  Widget app() => MaterialApp(
    theme: droverDarkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: VoiceScreen(
      session: VoiceSession(
        connect: () async => transport,
        mic: mic,
        speaker: speaker,
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

  testWidgets('starts on open and shows the hint until something is said', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Listening'), findsOneWidget);
    expect(find.textContaining('Ask about your agents'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);

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

    expect(find.text('One agent is blocked.'), findsOneWidget);
    expect(find.textContaining('Ask about your agents'), findsNothing);

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

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
