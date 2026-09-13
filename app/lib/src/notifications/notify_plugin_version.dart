/// The lowest `drover-notify` version this app build treats as current.
///
/// ponytail: pinned to the already-published 0.1.0, so the notice renders for
/// nobody today; bumping this constant on the next drover-notify release is
/// the one-line change that activates it.
const kMinNotifyPluginVersion = '0.1.0';

/// Whether the host's `drover-notify` is older than [kMinNotifyPluginVersion].
///
/// Anything that is not plain dot-separated integers — a prerelease suffix, a
/// git describe string, nothing at all — reads as not stale, so an unexpected
/// version string stays silent instead of raising a false alarm.
bool isNotifyPluginStale(String? installed) {
  final found = _segments(installed);
  if (found == null) return false;
  final minimum = _segments(kMinNotifyPluginVersion)!;
  final length = found.length > minimum.length ? found.length : minimum.length;
  for (var i = 0; i < length; i++) {
    final a = i < found.length ? found[i] : 0;
    final b = i < minimum.length ? minimum[i] : 0;
    if (a != b) return a < b;
  }
  return false;
}

/// One host whose `drover-notify` is behind [kMinNotifyPluginVersion], with
/// everything the update notice needs to render its reinstall commands.
class StaleNotifyPlugin {
  const StaleNotifyPlugin({
    required this.hostName,
    required this.installedVersion,
    required this.herdrBin,
  });

  final String hostName;
  final String installedVersion;
  final String herdrBin;
}

List<int>? _segments(String? version) {
  if (version == null) return null;
  final parts = version.split('.').map(int.tryParse).toList();
  return parts.contains(null) ? null : parts.cast<int>();
}
