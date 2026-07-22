import 'package:drover/src/agents/codex/codex_structured_prompt.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRequestUserInput', () {
    test('parses a single-question input with options and descriptions', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 'q1',
              'header': 'Next step',
              'question': 'Which approach?',
              'options': [
                {'label': 'Ship it', 'description': 'Deploy now'},
                {'label': 'Keep iterating'},
              ],
            },
          ],
        },
      );

      final prompt = parseRequestUserInput(toolUse);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'call_1');
      expect(prompt.questions, hasLength(1));
      final question = prompt.questions.single;
      expect(question.question, 'Which approach?');
      expect(question.header, 'Next step');
      expect(question.multiSelect, isFalse);
      expect(question.options, hasLength(2));
      expect(question.options[0].label, 'Ship it');
      expect(question.options[0].description, 'Deploy now');
      expect(question.options[1].label, 'Keep iterating');
      expect(question.options[1].description, isNull);
    });

    test('parses a multi-question input, preserving question order', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_multi',
        input: {
          'questions': [
            {
              'id': 'q1',
              'header': 'Priority',
              'question': 'What priority?',
              'options': [
                {'label': 'High'},
                {'label': 'Low'},
              ],
            },
            {
              'id': 'q2',
              'header': 'Style',
              'question': 'Which style?',
              'options': [
                {'label': 'Async'},
                {'label': 'Sync'},
              ],
            },
          ],
        },
      );

      final prompt = parseRequestUserInput(toolUse);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'call_multi');
      expect(prompt.questions, hasLength(2));
      expect(prompt.questions[0].question, 'What priority?');
      expect(prompt.questions[0].header, 'Priority');
      expect(prompt.questions[1].question, 'Which style?');
      expect(prompt.questions[1].header, 'Style');
    });

    test('uses empty string for a missing or non-string header', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 'q1',
              'question': 'Which approach?',
              'options': [
                {'label': 'Option A'},
              ],
            },
          ],
        },
      );

      final prompt = parseRequestUserInput(toolUse);

      expect(prompt!.questions.single.header, '');
    });

    test('returns null for the wrong tool name', () {
      final toolUse = TranscriptToolUse(
        name: 'Bash',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 'q1',
              'question': 'Which approach?',
              'options': [
                {'label': 'Option A'},
              ],
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when the tool_use has no id', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        input: {
          'questions': [
            {
              'id': 'q1',
              'question': 'Which approach?',
              'options': [
                {'label': 'Option A'},
              ],
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when questions is missing', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: const {},
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when questions is not a list', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: const {'questions': 'not a list'},
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when questions is an empty list', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: const {'questions': []},
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when a question entry is not a Map', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': ['not a map'],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when a question entry has no id field', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'question': 'Which approach?',
              'options': [
                {'label': 'Option A'},
              ],
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when a question id is not a String', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 42,
              'question': 'Which approach?',
              'options': [
                {'label': 'Option A'},
              ],
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when question text is missing', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 'q1',
              'options': [
                {'label': 'Option A'},
              ],
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when the tool_use id is blank or whitespace-only', () {
      for (final blank in ['', '   ', '\t']) {
        final toolUse = TranscriptToolUse(
          name: 'request_user_input',
          id: blank,
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Which approach?',
                'options': [
                  {'label': 'Option A'},
                ],
              },
            ],
          },
        );
        expect(
          parseRequestUserInput(toolUse),
          isNull,
          reason: 'blank tool_use id: "$blank"',
        );
      }
    });

    test('returns null when a question id is blank or whitespace-only', () {
      for (final blank in ['', '   ', '\t']) {
        final toolUse = TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': blank,
                'question': 'Which approach?',
                'options': [
                  {'label': 'Option A'},
                ],
              },
            ],
          },
        );
        expect(
          parseRequestUserInput(toolUse),
          isNull,
          reason: 'blank question id: "$blank"',
        );
      }
    });

    test('returns null when an option label is blank or whitespace-only', () {
      for (final blank in ['', '   ', '\t']) {
        final toolUse = TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Which approach?',
                'options': [
                  {'label': blank},
                ],
              },
            ],
          },
        );
        expect(
          parseRequestUserInput(toolUse),
          isNull,
          reason: 'blank option label: "$blank"',
        );
      }
    });

    test('returns null when question text is blank or whitespace-only', () {
      for (final blank in ['', '   ', '\t\n']) {
        final toolUse = TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': blank,
                'options': [
                  {'label': 'Option A'},
                ],
              },
            ],
          },
        );
        expect(
          parseRequestUserInput(toolUse),
          isNull,
          reason: 'blank: "$blank"',
        );
      }
    });

    test('returns null when options field is missing', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {'id': 'q1', 'question': 'Which approach?'},
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when options is not a list', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 'q1',
              'question': 'Which approach?',
              'options': 'not a list',
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test('returns null when options is an empty list', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {'id': 'q1', 'question': 'Which approach?', 'options': <dynamic>[]},
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test(
      'returns null when an option entry is not a Map (rejects whole call)',
      () {
        final toolUse = TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Which approach?',
                'options': ['not a map'],
              },
            ],
          },
        );

        expect(parseRequestUserInput(toolUse), isNull);
      },
    );

    test('returns null when an option has no label (rejects whole call)', () {
      final toolUse = TranscriptToolUse(
        name: 'request_user_input',
        id: 'call_1',
        input: {
          'questions': [
            {
              'id': 'q1',
              'question': 'Which approach?',
              'options': [
                {'label': 'Ship it'},
                {'description': 'missing label'},
              ],
            },
          ],
        },
      );

      expect(parseRequestUserInput(toolUse), isNull);
    });

    test(
      'returns null when any question in a multi-question set is malformed',
      () {
        // First question is valid; second has no options — the whole call is null.
        final toolUse = TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_multi',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'What priority?',
                'options': [
                  {'label': 'High'},
                ],
              },
              {'id': 'q2', 'question': 'Which style?', 'options': <dynamic>[]},
            ],
          },
        );

        expect(parseRequestUserInput(toolUse), isNull);
      },
    );
  });

  group('CodexStructuredPromptCapability.pendingPrompt', () {
    const capability = CodexStructuredPromptCapability();

    test('returns the prompt when a request_user_input call is unanswered', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Which approach?',
                'options': [
                  {'label': 'Ship it'},
                ],
              },
            ],
          },
        ),
      ]);

      final prompt = capability.pendingPrompt(transcript);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'call_1');
    });

    test('returns null once a matching tool_result has arrived', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Which approach?',
                'options': [
                  {'label': 'Ship it'},
                ],
              },
            ],
          },
        ),
        const TranscriptToolResult('call_1'),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });

    test('picks only the last unanswered call among several', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_1',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'First?',
                'options': [
                  {'label': 'Yes'},
                ],
              },
            ],
          },
        ),
        const TranscriptToolResult('call_1'),
        TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_2',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Second?',
                'options': [
                  {'label': 'Yes'},
                ],
              },
            ],
          },
        ),
        TranscriptToolUse(
          name: 'request_user_input',
          id: 'call_3',
          input: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Third?',
                'options': [
                  {'label': 'Yes'},
                ],
              },
            ],
          },
        ),
      ]);

      final prompt = capability.pendingPrompt(transcript);

      expect(prompt!.id, 'call_3');
    });

    test('returns null when there is no request_user_input tool_use', () {
      final transcript = NativeTranscript([
        const TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'Hello'),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });

    test('ignores unrelated tool uses', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'Bash',
          id: 'call_1',
          input: const {'command': 'ls'},
        ),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });

    test(
      'returns null when the pending tool_use has a malformed questions list',
      () {
        final transcript = NativeTranscript([
          TranscriptToolUse(
            name: 'request_user_input',
            id: 'call_1',
            input: const {
              'questions': [
                {'id': 'q1', 'question': 'Which?'},
              ],
            }, // options missing → parser returns null
          ),
        ]);

        expect(capability.pendingPrompt(transcript), isNull);
      },
    );
  });
}
