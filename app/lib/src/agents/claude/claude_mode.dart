// Claude Code's interaction mode: reading its wording off the TUI mode line,
// and cycling it with the raw backtab escape sequence.

import '../../herdr/herdr_client.dart';
import '../agent_capabilities.dart';

final _modeLine = RegExp(r'^\s*[⏸⏵]');

/// Reads the current [AgentMode] from the trailing mode line of [text] (e.g.
/// `-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)`). Returns null when no
/// mode line is present. Expects plain text — strip ANSI first.
///
/// Matching is by wording because the `⏵⏵`/`⏸` glyphs alone don't disambiguate
/// (`⏵⏵` fronts both auto-accept and bypass; `⏸` fronts both plan and the
/// default "manual" mode). Claude Code has phrased auto-accept as both
/// `auto mode on` and `accept edits on`, so both are matched; anything else on
/// a recognized mode line (e.g. `manual mode on`) is the default [AgentMode.normal].
AgentMode? parseAgentMode(String text) {
  final lines = text.split('\n');
  final start = lines.length > 6 ? lines.length - 6 : 0;
  for (var i = lines.length - 1; i >= start; i--) {
    final lower = lines[i].toLowerCase();
    final isModeLine =
        lower.contains('-- insert --') || _modeLine.hasMatch(lines[i]);
    if (!isModeLine) continue;
    if (lower.contains('plan')) return AgentMode.plan;
    if (lower.contains('bypass')) return AgentMode.bypass;
    if (lower.contains('auto') || lower.contains('accept')) {
      return AgentMode.autoAccept;
    }
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
