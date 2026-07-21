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
final _planIdleFooter = RegExp(r'\bplan\b\s+commands\b');
final _autopilotIdleFooter = RegExp(r'\bautopilot\b\s+commands\b');
final _planWrappedIdlePrefix = RegExp(
  r'^\s*plan\b[^a-zA-Z0-9\r\n]*/\s*$',
  caseSensitive: false,
);
final _autopilotWrappedIdlePrefix = RegExp(
  r'^\s*autopilot\b[^a-zA-Z0-9\r\n]*/\s*$',
  caseSensitive: false,
);

/// Reads the current [AgentMode] from the trailing footer area of [text].
///
/// Copilot CLI 1.0.72's composer footer comes in two forms, each of which
/// names a non-default mode explicitly:
/// - idle: `/ commands · ? help · tab next tab`, with `plan ·` or
///   `autopilot ·` prefixed when that mode is active.
/// - working: `◎ Working esc interrupt`, becoming `◉ Working - plan esc
///   interrupt` or `Working - autopilot esc interrupt` for those modes.
///
/// Narrow terminal panes can wrap the idle footer across multiple physical
/// lines (and a version-update notice can appear between its words), so the
/// trailing footer area is normalized as one string before matching.
///
/// A recognized footer area with neither mode word present maps to
/// [AgentMode.normal]. Returns null when no footer line is present (e.g. the
/// top-nav is focused instead of the composer, or the pane is showing
/// something else entirely) rather than guessing a mode from unrelated text
/// — notably, the top-nav's `Session | Issues | Pull requests | Gists` never
/// matches either footer shape, so it can't be mistaken for one. Expects
/// plain text — strip ANSI first.
AgentMode? parseCopilotMode(String text) {
  final lines = text.split('\n');
  final start = lines.length > 6 ? lines.length - 6 : 0;
  final trailingRawLines = lines.sublist(start);
  final trailingLines = trailingRawLines.map(_normalize).toList();
  final footer = trailingLines.join(' ');
  final isIdleFooter =
      footer.contains('commands') &&
      footer.contains('help') &&
      footer.contains('next') &&
      footer.contains('tab');
  final idleModeIndex = trailingLines.lastIndexWhere(
    (line) => line.contains('commands'),
  );
  final idleEnd = trailingLines.lastIndexWhere((line) => line.contains('tab'));
  final workingIndex = trailingLines.lastIndexWhere(
    (line) => line.contains('working') && line.contains('interrupt'),
  );

  // A scrolled-off working footer can remain above a newer idle footer.
  // Prefer the recognized footer closest to the bottom of the pane.
  if (workingIndex >= 0 && (!isIdleFooter || workingIndex > idleEnd)) {
    final workingFooter = trailingLines[workingIndex];
    if (_autopilotWord.hasMatch(workingFooter)) return AgentMode.autoAccept;
    if (_planWord.hasMatch(workingFooter)) return AgentMode.plan;
    return AgentMode.normal;
  }
  if (!isIdleFooter) return null;

  // The mode prefix is on the `commands` row or wraps immediately before it
  // as `<mode> · /`; a draft ending in "plan" lacks that footer delimiter.
  final idleModeLine = trailingLines[idleModeIndex];
  final precedingIdleLine = idleModeIndex == 0
      ? ''
      : trailingRawLines[idleModeIndex - 1];
  if (_autopilotIdleFooter.hasMatch(idleModeLine)) {
    return AgentMode.autoAccept;
  }
  if (_planIdleFooter.hasMatch(idleModeLine)) return AgentMode.plan;
  if (_autopilotWrappedIdlePrefix.hasMatch(precedingIdleLine)) {
    return AgentMode.autoAccept;
  }
  if (_planWrappedIdlePrefix.hasMatch(precedingIdleLine)) {
    return AgentMode.plan;
  }
  return AgentMode.normal;
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
