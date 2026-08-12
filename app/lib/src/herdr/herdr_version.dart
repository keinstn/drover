/// A herdr CLI version as (major, minor, patch).
typedef HerdrVersion = (int, int, int);

/// The oldest herdr version drover supports. `HerdrClient.prompt` uses `agent
/// prompt` with no fallback or version detection, and `startAgent`/`agent
/// wait` rely on the `--pane`/`--until` shapes — all 0.7.5-only behaviors
/// documented in docs/herdr-notes.md. Below this, starting an agent errors.
/// Raised from 0.7.5 to 0.8.0 on 2026-08-13 as a deliberate diagnosability
/// floor, not because a command shape changed: 0.8.0 is the first version that
/// reports a stopped herdr server as a `server_not_running` error envelope,
/// which `app_error.dart` classifies into a message naming herdr rather than
/// the network. On 0.7.x that same failure surfaces as a bare `Error: Os
/// { ... }` string users misread as an SSH failure (issue #160), and drover
/// deliberately does not parse it.
const kMinHerdrVersion = (0, 8, 0);

/// Extracts the first `major.minor.patch` run of digits from raw `herdr
/// --version` stdout (e.g. `"herdr 0.7.5\n"`), or null if none is found.
HerdrVersion? parseHerdrVersion(String raw) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw);
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

/// Whether [version] meets [kMinHerdrVersion].
bool isHerdrVersionSupported(HerdrVersion version) {
  final (major, minor, patch) = version;
  final (minMajor, minMinor, minPatch) = kMinHerdrVersion;
  if (major != minMajor) return major > minMajor;
  if (minor != minMinor) return minor > minMinor;
  return patch >= minPatch;
}

/// `"major.minor.patch"`, for display in warning messages.
String formatHerdrVersion(HerdrVersion version) =>
    '${version.$1}.${version.$2}.${version.$3}';

/// Thrown by the herd screen's version gate when a host's herdr is older than
/// [kMinHerdrVersion] — not a herdr-reported error, so it is a distinct type
/// from [HerdrException] (classified by `app_error.dart` the same way bare SSH
/// exceptions are, alongside the `HerdrException`-wrapped cases).
class HerdrVersionUnsupportedException implements Exception {
  const HerdrVersionUnsupportedException({
    required this.found,
    required this.minimum,
  });

  /// The host's herdr version, formatted (e.g. `"0.7.0"`).
  final String found;

  /// [kMinHerdrVersion], formatted (e.g. `"0.7.5"`).
  final String minimum;

  @override
  String toString() =>
      'HerdrVersionUnsupportedException(found: $found, minimum: $minimum)';
}
