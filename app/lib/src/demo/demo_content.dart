// The demo session's scripted *content*, selected by locale.
//
// Deliberately Dart source rather than ARB: the assistant turns are
// multi-paragraph Markdown with fenced code blocks, which ARB's escaping makes
// unreadable. ARB stays for drover's own UI strings.
//
// The locale boundary this file encodes (see the field docs below):
//
//  - LOCALIZED — anything a *person* would have written or that the agent
//    wrote as prose: user turns, session titles, the assistant's thinking and
//    explanations.
//  - ENGLISH ALWAYS — anything the *CLI* emits: permission-prompt bodies, live
//    terminal text, the mode indicator, tool names, and code/diff contents. A
//    Japanese developer really does see English CLI chrome in production, and
//    drover's own parsers match literals like `'Esc to cancel'`
//    (`claude_askuser_submitter.dart`), so translating CLI output would both
//    fabricate output the real tool never emits and risk breaking those
//    parsers.
library;

import 'dart:ui' show Locale;

import 'demo_content_en.dart';
import 'demo_content_ja.dart';

/// Every locale-dependent string in the scripted demo session. Code and diff
/// bodies are NOT here — they live inside [assistantTour] verbatim and stay
/// English in every locale (see the library doc).
class DemoContent {
  const DemoContent({
    required this.scriptedTitle,
    required this.reviewTitle,
    required this.docsTitle,
    required this.userTour,
    required this.assistantTour,
    required this.userSetup,
    required this.thinking,
    required this.reply1,
    required this.reply2,
  });

  /// Session title of the interactive agent — a herdr session title is derived
  /// from what the user asked for, so it follows the user's language.
  final String scriptedTitle;

  /// Session titles of the two non-interactive agents that give the herd
  /// screen real status counts.
  final String reviewTitle;
  final String docsTitle;

  /// The user's opening turn.
  final String userTour;

  /// The assistant's reply: Markdown prose (localized) wrapped around a fenced
  /// Dart block and a fenced diff (English, verbatim in every locale).
  final String assistantTour;

  /// The user's second turn — the one whose tool call is still awaiting
  /// permission when the demo opens.
  final String userSetup;

  /// The assistant's thinking block before that tool call.
  final String thinking;

  /// The reply that lands after the permission prompt is answered.
  final String reply1;

  /// The reply that lands after the user's own free-text follow-up, ending
  /// the script.
  final String reply2;
}

/// The demo content for [locale], falling back to English for every locale
/// drover has no scripted session for.
DemoContent demoContentFor(Locale? locale) =>
    locale?.languageCode == 'ja' ? demoContentJa : demoContentEn;

/// The fenced Dart block inside every locale's [DemoContent.assistantTour].
/// Shared rather than copied per locale: it is file content, not prose, so it
/// must stay byte-identical everywhere.
///
/// The signature is wrapped across lines — which is what `dart format` does to
/// it anyway — so no line needs horizontal scrolling to read at phone width.
const demoCodeFence = '''
```dart
Future<T> withRetry<T>(
  Future<T> Function() run, {
  int attempts = 3,
}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      return await run();
    } catch (_) {
      if (i == attempts - 1) rethrow;
    }
  }
  throw StateError('unreachable');
}
```''';

/// The fenced diff inside every locale's [DemoContent.assistantTour] — English
/// always, for the same reason as [demoCodeFence].
const demoDiffFence = '''
```diff
-  for (var i = 0; ; i++) {
+  for (var i = 0; i < attempts; i++) {
     try {
       return await run();
     } catch (_) {
-      if (i >= attempts - 1) rethrow;
+      if (i == attempts - 1) rethrow;
     }
   }
```''';
