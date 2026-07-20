import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/screens/askuser_sheet.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A lone single-select question with a described first option.
const _singleOnly = AskUserQuestionPrompt(
  toolUseId: 't1',
  questions: [
    AskUserQuestionItem(
      question: 'Which environment?',
      header: 'Environment',
      multiSelect: false,
      options: [
        AskUserQuestionOption(label: 'Staging', description: 'safe sandbox'),
        AskUserQuestionOption(label: 'Production'),
      ],
    ),
  ],
);

// A lone multi-select question.
const _multiOnly = AskUserQuestionPrompt(
  toolUseId: 't2',
  questions: [
    AskUserQuestionItem(
      question: 'Which checks?',
      header: 'Checks',
      multiSelect: true,
      options: [
        AskUserQuestionOption(label: 'Unit'),
        AskUserQuestionOption(label: 'Integration'),
        AskUserQuestionOption(label: 'Lint'),
      ],
    ),
  ],
);

// A single-select question followed by a multi-select one.
const _twoQuestions = AskUserQuestionPrompt(
  toolUseId: 't3',
  questions: [
    AskUserQuestionItem(
      question: 'Pick one',
      header: '',
      multiSelect: false,
      options: [
        AskUserQuestionOption(label: 'One'),
        AskUserQuestionOption(label: 'Two'),
      ],
    ),
    AskUserQuestionItem(
      question: 'Pick many',
      header: '',
      multiSelect: true,
      options: [
        AskUserQuestionOption(label: 'X'),
        AskUserQuestionOption(label: 'Y'),
      ],
    ),
  ],
);

/// Records what the injected submit callback was handed, standing in for the
/// real key-injection submitter so the sheet stays host-free in tests.
class _Recorder {
  int calls = 0;
  List<AskUserQuestionAnswer>? answers;
  bool fail = false;

  Future<void> submit(List<AskUserQuestionAnswer> answers) async {
    calls++;
    this.answers = answers;
    if (fail) throw StateError('boom');
  }
}

/// Pumps a page that opens [prompt]'s sheet via `showModalBottomSheet`, so
/// Cancel/Send can pop a real route.
Future<void> _openSheet(
  WidgetTester tester,
  AskUserQuestionPrompt prompt,
  _Recorder recorder,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    AskUserSheet(prompt: prompt, onSubmit: recorder.submit),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

VoidCallback? _sendPressed(WidgetTester tester) => tester
    .widget<FilledButton>(find.byKey(const ValueKey('askuser_send_button')))
    .onPressed;

void main() {
  testWidgets('renders each question, its options, and the custom field', (
    tester,
  ) async {
    await _openSheet(tester, _singleOnly, _Recorder());

    expect(find.text('Environment'), findsOneWidget);
    expect(find.text('Which environment?'), findsOneWidget);
    expect(find.text('Staging'), findsOneWidget);
    expect(find.text('safe sandbox'), findsOneWidget);
    expect(find.text('Production'), findsOneWidget);
    expect(find.text('Type something…'), findsOneWidget);
  });

  testWidgets('radios enforce a single selection', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _singleOnly, recorder);

    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt1')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('askuser_send_button')));
    await tester.pumpAndSettle();

    expect(recorder.answers, hasLength(1));
    expect(recorder.answers!.single.selectedIndexes, [1]);
    expect(recorder.answers!.single.customText, isNull);
  });

  testWidgets('checkboxes allow multiple selections', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _multiOnly, recorder);

    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt2')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('askuser_send_button')));
    await tester.pumpAndSettle();

    expect(recorder.answers!.single.selectedIndexes, [0, 2]);
    expect(recorder.answers!.single.customText, isNull);
  });

  testWidgets('a multi-select question shows no custom field', (tester) async {
    await _openSheet(tester, _multiOnly, _Recorder());

    expect(find.byKey(const ValueKey('askuser_q0_custom')), findsNothing);
  });

  testWidgets('multi-select keeps Send disabled until an option is checked', (
    tester,
  ) async {
    await _openSheet(tester, _multiOnly, _Recorder());

    expect(_sendPressed(tester), isNull);

    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt1')));
    await tester.pump();

    expect(_sendPressed(tester), isNotNull);
  });

  testWidgets(
    'typing custom text clears the selected option and enables Send',
    (tester) async {
      final recorder = _Recorder();
      await _openSheet(tester, _singleOnly, recorder);

      // Nothing answered yet: Send is disabled.
      expect(_sendPressed(tester), isNull);

      await tester.tap(find.byKey(const ValueKey('askuser_q0_opt0')));
      await tester.pump();
      expect(_sendPressed(tester), isNotNull);

      await tester.enterText(
        find.byKey(const ValueKey('askuser_q0_custom')),
        'roll my own',
      );
      await tester.pump();
      expect(_sendPressed(tester), isNotNull);

      await tester.tap(find.byKey(const ValueKey('askuser_send_button')));
      await tester.pumpAndSettle();

      expect(recorder.answers!.single.customText, 'roll my own');
      expect(recorder.answers!.single.selectedIndexes, isEmpty);
    },
  );

  testWidgets('selecting an option clears the custom text', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _singleOnly, recorder);

    await tester.enterText(
      find.byKey(const ValueKey('askuser_q0_custom')),
      'roll my own',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt1')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('askuser_send_button')));
    await tester.pumpAndSettle();

    expect(recorder.answers!.single.selectedIndexes, [1]);
    expect(recorder.answers!.single.customText, isNull);
  });

  testWidgets('Send stays disabled until every question is answered', (
    tester,
  ) async {
    await _openSheet(tester, _twoQuestions, _Recorder());

    expect(_sendPressed(tester), isNull);

    await tester.ensureVisible(find.byKey(const ValueKey('askuser_q0_opt0')));
    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt0')));
    await tester.pump();
    // First question answered, second still open.
    expect(_sendPressed(tester), isNull);

    await tester.ensureVisible(find.byKey(const ValueKey('askuser_q1_opt0')));
    await tester.tap(find.byKey(const ValueKey('askuser_q1_opt0')));
    await tester.pump();
    expect(_sendPressed(tester), isNotNull);
  });

  testWidgets('Send builds one answer per question in order', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _twoQuestions, recorder);

    await tester.ensureVisible(find.byKey(const ValueKey('askuser_q0_opt1')));
    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt1')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('askuser_q1_opt0')));
    await tester.tap(find.byKey(const ValueKey('askuser_q1_opt0')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('askuser_q1_opt1')));
    await tester.tap(find.byKey(const ValueKey('askuser_q1_opt1')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('askuser_send_button')));
    await tester.pumpAndSettle();

    expect(recorder.answers, hasLength(2));
    expect(recorder.answers![0].selectedIndexes, [1]);
    expect(recorder.answers![0].customText, isNull);
    expect(recorder.answers![1].selectedIndexes, [0, 1]);
    expect(recorder.answers![1].customText, isNull);
  });

  testWidgets('Cancel dismisses without submitting', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _singleOnly, recorder);

    expect(find.byType(AskUserSheet), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('askuser_cancel_button')));
    await tester.pumpAndSettle();

    expect(find.byType(AskUserSheet), findsNothing);
    expect(recorder.calls, 0);
  });

  testWidgets('a failed submit keeps the sheet open', (tester) async {
    final recorder = _Recorder()..fail = true;
    await _openSheet(tester, _singleOnly, recorder);

    await tester.tap(find.byKey(const ValueKey('askuser_q0_opt0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('askuser_send_button')));
    await tester.pumpAndSettle();

    expect(recorder.calls, 1);
    expect(find.byType(AskUserSheet), findsOneWidget);
  });
}
