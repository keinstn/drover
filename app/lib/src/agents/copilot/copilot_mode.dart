// GitHub Copilot CLI's interaction mode: reading its wording off the
// composer's footer, and cycling it with the same raw backtab escape
// sequence Claude Code uses.
//
// See docs/herdr-notes.md for the observed shape of Copilot CLI 1.0.72's
// footer this is matched against.

import '../../herdr/herdr_client.dart';
import '../agent_capabilities.dart';

/// Strips everything but ASCII letters/digits/spaces/hyphens, lowercases,
/// and collapses whitespace, so footer matching is tolerant of Copilot's
/// status glyphs (`◎`/`◉`/etc.), its `·` separators, and any spacing/case
/// differences between builds, while still requiring the exact wording
/// observed live.
String _normalize(String line) {
  return line
      .replaceAll(RegExp(r'[^a-zA-Z0-9\s-]'), ' ')
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

final _planWord = RegExp(r'\bplan\b');
final _autopilotWord = RegExp(r'\bautopilot\b');

/// Reads the current [AgentMode] from the trailing footer line of [text].
///
/// Copilot CLI 1.0.72's composer footer comes in two forms, each of which
/// names a non-default mode explicitly:
/// - idle: `/ commands · ? help · tab next tab`, with `plan ·` or
///   `autopilot ·` prefixed when that mode is active.
/// - working: `◎ Working esc interrupt`, becoming `◉ Working - plan esc
///   interrupt` or `Working - autopilot esc interrupt` for those modes.
///
/// A recognized footer line with neither mode word present maps to
/// [AgentMode.normal]. Returns null when no footer line is present (e.g. the
/// top-nav is focused instead of the composer, or the pane is showing
/// something else entirely) rather than guessing a mode from unrelated text
/// — notably, the top-nav's `Session | Issues | Pull requests | Gists` never
/// matches either footer shape, so it can't be mistaken for one. Expects
/// plain text — strip ANSI first.
AgentMode? parseCopilotMode(String text) {
  final lines = text.split('\n');
  final start = lines.length > 6 ? lines.length - 6 : 0;
  for (var i = lines.length - 1; i >= start; i--) {
    final normalized = _normalize(lines[i]);
    if (normalized.isEmpty) continue;

    final isIdleFooter =
        normalized.contains('commands') &&
        normalized.contains('help') &&
        normalized.contains('next tab');
    final isWorkingFooter =
        normalized.contains('working') && normalized.contains('interrupt');
    if (!isIdleFooter && !isWorkingFooter) continue;

    if (_autopilotWord.hasMatch(normalized)) return AgentMode.autoAccept;
    if (_planWord.hasMatch(normalized)) return AgentMode.plan;
    return AgentMode.normal;
  }
  return null;
}

/// Reads and cycles Copilot CLI's interaction mode.
class CopilotModeCapability implements AgentModeCapability {
  const CopilotModeCapability();

  @override
  AgentMode? parseMode(String paneText) => parseCopilotMode(paneText);

  /// Cycle the agent's interaction mode — the runtime equivalent of pressing
  /// shift+tab with the composer focused. As with Claude Code, herdr's `pane
  /// send-keys shift+tab` mis-encodes to a plain Tab (herdr issue #1561), so
  /// send the raw backtab escape sequence (ESC [ Z) via `pane send-text`
  /// instead — verified on live Copilot CLI 1.0.72 to cycle
  /// interactive -> plan -> autopilot -> interactive.
  @override
  Future<void> cycleMode(HerdrClient client, String paneId) =>
      client.sendPaneText(paneId, '\u001b[Z');
}
