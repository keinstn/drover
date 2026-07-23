// Claude Code's interaction mode: reading its wording off the TUI mode line,
// and cycling it with the raw backtab escape sequence.

import '../../herdr/herdr_client.dart';
import '../agent_capabilities.dart';

final _modeGlyph = RegExp(r'[⏸⏵]+');
final _cycleHint = RegExp(r'\(shift\+tab to cycle\)', caseSensitive: false);

/// Reads the current [AgentMode] from the trailing mode line of [text] (e.g.
/// `-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)`). Returns null when no
/// mode line is present. Expects plain text — strip ANSI first.
///
/// The mode name is read from the text between the `⏵⏵`/`⏸` glyph and the
/// following `(shift+tab to cycle)` (or line end, if that hint is absent) —
/// matching only within that window keeps unrelated leading/trailing text on
/// the line (the vim-style `-- INSERT --` prefix, trailing hints like `· ←
/// for agents`) from being mistaken for the mode name. This matters because
/// that prefix isn't consistently formatted: in insert mode, most modes render
/// as `-- INSERT -- ⏵⏵ ...` but bypass renders as `-- INSERT   ⏵⏵ ...` (no
/// second `--`), so matching against the whole line missed bypass while
/// composing a prompt (issue #62).
///
/// The glyphs alone don't disambiguate (`⏵⏵` fronts [AgentMode.acceptEdit],
/// [AgentMode.auto], and [AgentMode.bypass]; `⏸` fronts both
/// [AgentMode.plan] and the default "manual" mode). `accept edits on` and
/// `auto mode on` are separate cycle stops (issue #62) and resolve to
/// [AgentMode.acceptEdit] and [AgentMode.auto] respectively; anything else on
/// a recognized mode line (e.g. `manual mode on`) is the default
/// [AgentMode.normal].
AgentMode? parseAgentMode(String text) {
  final lines = text.split('\n');
  final start = lines.length > 6 ? lines.length - 6 : 0;
  for (var i = lines.length - 1; i >= start; i--) {
    final line = lines[i];
    final glyphMatch = _modeGlyph.firstMatch(line);
    // Claude Code can show the vim "-- INSERT --" indicator before the mode
    // name renders (or with no mode name at all); still count it as a
    // recognized mode line so it resolves to AgentMode.normal below instead
    // of falling through to null (which would hide the mode button).
    final hasInsert = line.toLowerCase().contains('-- insert');
    if (glyphMatch == null && !hasInsert) continue;

    final afterGlyph = glyphMatch == null ? '' : line.substring(glyphMatch.end);
    final cycleMatch = _cycleHint.firstMatch(afterGlyph);
    final modeText =
        (cycleMatch == null
                ? afterGlyph
                : afterGlyph.substring(0, cycleMatch.start))
            .trim()
            .toLowerCase();

    if (modeText.contains('plan')) return AgentMode.plan;
    if (modeText.contains('bypass')) return AgentMode.bypass;
    if (modeText.contains('accept')) return AgentMode.acceptEdit;
    if (modeText.contains('auto')) return AgentMode.auto;
    return AgentMode.normal;
  }
  return null;
}

/// Reads and cycles Claude Code's interaction mode.
class ClaudeModeCapability implements AgentModeCapability {
  const ClaudeModeCapability();

  @override
  AgentMode? parseMode(String paneText) => parseAgentMode(paneText);

  /// Cycle the agent's interaction mode — the runtime equivalent of pressing
  /// shift+tab. herdr's `pane send-keys shift+tab` mis-encodes to a plain Tab
  /// for kitty-keyboard agents like Claude Code (herdr issue #1561), so send
  /// the raw backtab escape sequence (ESC [ Z) via `pane send-text`, which is
  /// verified to cycle the mode end-to-end.
  @override
  Future<void> cycleMode(HerdrClient client, String paneId) =>
      client.sendPaneText(paneId, '\u001b[Z');
}
