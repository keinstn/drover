// Codex CLI's interaction mode: reading it from the composer footer and
// cycling with the raw backtab escape sequence.
//
// Observed on Codex CLI 0.144.6: the composer footer reads
// `<model> <effort> · <cwd>` in default mode, and appends
// `Plan mode (shift+tab to cycle)` in plan mode. There is no third mode
// (no autoAccept/bypass cycle). The middot `·` followed by a path segment
// (`~/` or `/`) is the distinctive footer chrome; pane text without that
// chrome — including working states, dialogs, and transcript prose — returns
// null.

import '../../herdr/herdr_client.dart';
import '../agent_capabilities.dart';

// Footer chrome: the Codex status bar's `· ~/path` or `· /path` separator.
// This pattern is unique to the Codex composer footer and won't appear in
// transcript prose or other TUI chrome.
final _footerChrome = RegExp(r'·\s+[~/]');

// Matches the plan-mode label appended to the footer (case-insensitive so
// minor wording changes across CLI versions don't break parsing).
final _planModeText = RegExp(r'plan\s+mode\b', caseSensitive: false);

/// Reads the current [AgentMode] from the trailing footer area of [text].
///
/// Returns [AgentMode.normal] when the footer chrome is present with no mode
/// label, [AgentMode.plan] when `Plan mode` follows the chrome, and null when
/// no recognized footer is found (e.g. the pane is in a working/dialog/nav
/// state). Expects plain text — strip ANSI first.
AgentMode? parseCodexMode(String text) {
  final lines = text.split('\n');
  final start = lines.length > 6 ? lines.length - 6 : 0;
  final trailing = lines.sublist(start);

  // Locate the last line containing the footer chrome.
  var footerIdx = -1;
  for (var i = trailing.length - 1; i >= 0; i--) {
    if (_footerChrome.hasMatch(trailing[i])) {
      footerIdx = i;
      break;
    }
  }
  if (footerIdx < 0) return null;

  // Combine the footer line and any lines after it (the plan-mode label may
  // appear on the same line or wrap to the next in a narrow pane).
  final region = trailing.sublist(footerIdx).join('\n');
  if (_planModeText.hasMatch(region)) return AgentMode.plan;
  return AgentMode.normal;
}

/// Reads and cycles Codex CLI's interaction mode.
class CodexModeCapability implements AgentModeCapability {
  const CodexModeCapability();

  @override
  AgentMode? parseMode(String paneText) => parseCodexMode(paneText);

  /// Cycle the agent's interaction mode — the runtime equivalent of pressing
  /// shift+tab with the composer focused. herdr's `pane send-keys shift+tab`
  /// mis-encodes to a plain Tab for kitty-keyboard agents (herdr issue #1561),
  /// so send the raw backtab escape sequence (ESC [ Z) via `pane send-text`,
  /// verified on live Codex CLI 0.144.6 to cycle normal → plan → normal.
  @override
  Future<void> cycleMode(HerdrClient client, String paneId) =>
      client.sendPaneText(paneId, '\u001b[Z');
}
