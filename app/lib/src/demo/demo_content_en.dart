// English content for the scripted demo session. See `demo_content.dart` for
// the localized / deliberately-English boundary — the fenced Dart and diff
// bodies pulled in below are shared verbatim with every other locale.
import 'demo_content.dart';

const demoContentEn = DemoContent(
  scriptedTitle: 'Set up a demo file',
  reviewTitle: 'Review the billing webhook',
  docsTitle: 'Update the README',
  userTour: 'Give me a quick tour of the retry helper.',
  assistantTour:
      '## Retry helper\n'
      '\n'
      '`withRetry` wraps a call and retries it when it fails. Two things '
      'matter:\n'
      '\n'
      '- **attempts** — how many tries it gets before giving up\n'
      '- *rethrow* — the last failure is surfaced, never swallowed\n'
      '\n'
      '$demoCodeFence\n'
      '\n'
      'The loop bound was the bug. Here is the fix as a diff:\n'
      '\n'
      '$demoDiffFence',
  userSetup: 'Can you set up a quick test file so I can see how this works?',
  thinking: "I'll create an empty file with touch.",
  reply1:
      "Done — I've created spike-test.txt. Want me to add something to it, "
      'or ask me anything else?',
  reply2:
      "Happy to help with that too — in a real session I'd go read the "
      "relevant files and make the change. This demo's script ends here, "
      'though.',
);
