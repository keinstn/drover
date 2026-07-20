import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/screens/structured_prompt_sheet.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A lone single-select question with a described first option.
const _singleOnly = StructuredPrompt(
  id: 't1',
  questions: [
    StructuredPromptQuestion(
      question: 'Which environment?',
      header: 'Environment',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Staging', description: 'safe sandbox'),
        StructuredPromptOption(label: 'Production'),
      ],
    ),
  ],
);

// A lone multi-select question.
const _multiOnly = StructuredPrompt(
  id: 't2',
  questions: [
    StructuredPromptQuestion(
      question: 'Which checks?',
      header: 'Checks',
      multiSelect: true,
      options: [
        StructuredPromptOption(label: 'Unit'),
        StructuredPromptOption(label: 'Integration'),
        StructuredPromptOption(label: 'Lint'),
      ],
    ),
  ],
);

// A single-select question followed by a multi-select one.
const _twoQuestions = StructuredPrompt(
  id: 't3',
  questions: [
    StructuredPromptQuestion(
      question: 'Pick one',
      header: '',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'One'),
        StructuredPromptOption(label: 'Two'),
      ],
    ),
    StructuredPromptQuestion(
      question: 'Pick many',
      header: '',
      multiSelect: true,
      options: [
        StructuredPromptOption(label: 'X'),
        StructuredPromptOption(label: 'Y'),
      ],
    ),
  ],
);

/// Records what the injected submit callback was handed, standing in for the
/// real key-injection submitter so the sheet stays host-free in tests.
class _Recorder {
  int calls = 0;
  List<StructuredPromptAnswer>? answers;
  bool fail = false;

  Future<void> submit(List<StructuredPromptAnswer> answers) async {
    calls++;
    this.answers = answers;
    if (fail) throw StateError('boom');
  }
}

/// Pumps a page that opens [prompt]'s sheet via `showModalBottomSheet`, so
/// Cancel/Send can pop a real route.
Future<void> _openSheet(
  WidgetTester tester,
  StructuredPrompt prompt,
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
                builder: (_) => StructuredPromptSheet(
                  prompt: prompt,
                  onSubmit: recorder.submit,
                ),
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
    .widget<FilledButton>(
      find.byKey(const ValueKey('structured_prompt_send_button')),
    )
    .onPressed;

void main() {
  testWidgets(
    'renders each question, its options, and the custom field toggle',
    (tester) async {
      await _openSheet(tester, _singleOnly, _Recorder());

      expect(find.text('Environment'), findsOneWidget);
      expect(find.text('Which environment?'), findsOneWidget);
      expect(find.text('Staging'), findsOneWidget);
      expect(find.text('safe sandbox'), findsOneWidget);
      expect(find.text('Production'), findsOneWidget);
      // The custom field starts collapsed behind its tap-to-expand toggle.
      expect(
        find.byKey(const ValueKey('structured_prompt_q0_custom_toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('structured_prompt_q0_custom')),
        findsNothing,
      );
    },
  );

  testWidgets('radios enforce a single selection', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _singleOnly, recorder);

    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt1')));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('structured_prompt_send_button')),
    );
    await tester.pumpAndSettle();

    expect(recorder.answers, hasLength(1));
    expect(recorder.answers!.single.selectedIndexes, [1]);
    expect(recorder.answers!.single.customText, isNull);
  });

  testWidgets('checkboxes allow multiple selections', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _multiOnly, recorder);

    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt2')));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('structured_prompt_send_button')),
    );
    await tester.pumpAndSettle();

    expect(recorder.answers!.single.selectedIndexes, [0, 2]);
    expect(recorder.answers!.single.customText, isNull);
  });

  testWidgets('a multi-select question shows no custom field or toggle', (
    tester,
  ) async {
    await _openSheet(tester, _multiOnly, _Recorder());

    expect(
      find.byKey(const ValueKey('structured_prompt_q0_custom')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('structured_prompt_q0_custom_toggle')),
      findsNothing,
    );
  });

  testWidgets('multi-select keeps Send disabled until an option is checked', (
    tester,
  ) async {
    await _openSheet(tester, _multiOnly, _Recorder());

    expect(_sendPressed(tester), isNull);

    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt1')));
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

      await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt0')));
      await tester.pump();
      expect(_sendPressed(tester), isNotNull);

      await tester.tap(
        find.byKey(const ValueKey('structured_prompt_q0_custom_toggle')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('structured_prompt_q0_custom')),
        'roll my own',
      );
      await tester.pump();
      expect(_sendPressed(tester), isNotNull);

      await tester.tap(
        find.byKey(const ValueKey('structured_prompt_send_button')),
      );
      await tester.pumpAndSettle();

      expect(recorder.answers!.single.customText, 'roll my own');
      expect(recorder.answers!.single.selectedIndexes, isEmpty);
    },
  );

  testWidgets(
    'selecting an option clears the custom text and re-collapses it',
    (tester) async {
      final recorder = _Recorder();
      await _openSheet(tester, _singleOnly, recorder);

      await tester.tap(
        find.byKey(const ValueKey('structured_prompt_q0_custom_toggle')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('structured_prompt_q0_custom')),
        'roll my own',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt1')));
      await tester.pump();

      // Selecting an option collapses the custom field back to its toggle.
      expect(
        find.byKey(const ValueKey('structured_prompt_q0_custom')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('structured_prompt_q0_custom_toggle')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('structured_prompt_send_button')),
      );
      await tester.pumpAndSettle();

      expect(recorder.answers!.single.selectedIndexes, [1]);
      expect(recorder.answers!.single.customText, isNull);
    },
  );

  testWidgets('Send stays disabled until every question is answered', (
    tester,
  ) async {
    await _openSheet(tester, _twoQuestions, _Recorder());

    expect(_sendPressed(tester), isNull);

    await tester.ensureVisible(
      find.byKey(const ValueKey('structured_prompt_q0_opt0')),
    );
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt0')));
    await tester.pump();
    // First question answered, second still open.
    expect(_sendPressed(tester), isNull);

    await tester.ensureVisible(
      find.byKey(const ValueKey('structured_prompt_q1_opt0')),
    );
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q1_opt0')));
    await tester.pump();
    expect(_sendPressed(tester), isNotNull);
  });

  testWidgets('Send builds one answer per question in order', (tester) async {
    final recorder = _Recorder();
    await _openSheet(tester, _twoQuestions, recorder);

    await tester.ensureVisible(
      find.byKey(const ValueKey('structured_prompt_q0_opt1')),
    );
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt1')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('structured_prompt_q1_opt0')),
    );
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q1_opt0')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('structured_prompt_q1_opt1')),
    );
    await tester.tap(find.byKey(const ValueKey('structured_prompt_q1_opt1')));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('structured_prompt_send_button')),
    );
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

    expect(find.byType(StructuredPromptSheet), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('structured_prompt_cancel_button')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StructuredPromptSheet), findsNothing);
    expect(recorder.calls, 0);
  });

  testWidgets('a failed submit keeps the sheet open', (tester) async {
    final recorder = _Recorder()..fail = true;
    await _openSheet(tester, _singleOnly, recorder);

    await tester.tap(find.byKey(const ValueKey('structured_prompt_q0_opt0')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('structured_prompt_send_button')),
    );
    await tester.pumpAndSettle();

    expect(recorder.calls, 1);
    expect(find.byType(StructuredPromptSheet), findsOneWidget);
  });
}
