// Minimal ANSI SGR parser for herdr `agent read --format ansi` output. The
// `recent` source emits only SGR (colour/bold) escapes — no cursor movement or
// erase sequences — so we only need to track a foreground colour and a bold
// flag and split the text into styled runs.

import 'dart:ui' show Color;

final _sgr = RegExp('\\[([0-9;]*)m');
final _anyAnsi = RegExp('\\[[0-9;?]*[A-Za-z]');

/// Removes every ANSI escape sequence from [s], leaving plain text. A no-op on
/// text that has none, so it is safe to run on already-plain output.
String stripAnsi(String s) => s.replaceAll(_anyAnsi, '');

/// A run of text sharing one style.
class AnsiSpan {
  const AnsiSpan(this.text, {this.color, this.bold = false});

  final String text;
  final Color? color;
  final bool bold;
}

/// Splits [text] into [AnsiSpan]s, interpreting SGR escapes. Unrecognized SGR
/// parameters are skipped; a null [AnsiSpan.color] means "use the default
/// foreground". Style state carries across newlines, as a terminal would.
List<AnsiSpan> parseAnsi(String text) {
  final spans = <AnsiSpan>[];
  Color? color;
  var bold = false;
  var cursor = 0;

  void emit(String run) {
    if (run.isEmpty) return;
    spans.add(AnsiSpan(run, color: color, bold: bold));
  }

  for (final match in _sgr.allMatches(text)) {
    emit(text.substring(cursor, match.start));
    cursor = match.end;
    final params = _parseParams(match.group(1)!);
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      switch (code) {
        case 0:
          color = null;
          bold = false;
        case 1:
          bold = true;
        case 22:
          bold = false;
        case 39:
          color = null;
        case 38:
          // Extended foreground: 38;2;r;g;b or 38;5;n.
          if (i + 1 < params.length &&
              params[i + 1] == 2 &&
              i + 4 < params.length) {
            color = Color.fromARGB(
              255,
              params[i + 2] & 0xFF,
              params[i + 3] & 0xFF,
              params[i + 4] & 0xFF,
            );
            i += 4;
          } else if (i + 1 < params.length &&
              params[i + 1] == 5 &&
              i + 2 < params.length) {
            color = _xterm256(params[i + 2]);
            i += 2;
          }
        default:
          if (code >= 30 && code <= 37) {
            color = _basic[code - 30];
          } else if (code >= 90 && code <= 97) {
            color = _basic[code - 90 + 8];
          }
      }
      i++;
    }
  }
  emit(text.substring(cursor));
  return spans;
}

List<int> _parseParams(String raw) {
  if (raw.isEmpty) return const [0];
  return raw.split(';').map((p) => p.isEmpty ? 0 : int.parse(p)).toList();
}

/// Standard xterm 256-colour palette entry.
Color _xterm256(int n) {
  if (n < 16) return _basic[n];
  if (n < 232) {
    final c = n - 16;
    int level(int v) => v == 0 ? 0 : 55 + v * 40;
    return Color.fromARGB(
      255,
      level((c ~/ 36) % 6),
      level((c ~/ 6) % 6),
      level(c % 6),
    );
  }
  final g = 8 + (n - 232) * 10;
  return Color.fromARGB(255, g, g, g);
}

const _basic = <Color>[
  Color(0xFF000000), // black
  Color(0xFFCD0000), // red
  Color(0xFF00CD00), // green
  Color(0xFFCDCD00), // yellow
  Color(0xFF2222EE), // blue
  Color(0xFFCD00CD), // magenta
  Color(0xFF00CDCD), // cyan
  Color(0xFFE5E5E5), // white
  Color(0xFF7F7F7F), // bright black
  Color(0xFFFF0000), // bright red
  Color(0xFF00FF00), // bright green
  Color(0xFFFFFF00), // bright yellow
  Color(0xFF5C5CFF), // bright blue
  Color(0xFFFF00FF), // bright magenta
  Color(0xFF00FFFF), // bright cyan
  Color(0xFFFFFFFF), // bright white
];
