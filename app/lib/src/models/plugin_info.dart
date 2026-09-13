/// A Herdr plugin entry from `herdr plugin list --json`.
class PluginInfo {
  const PluginInfo({
    required this.pluginId,
    required this.enabled,
    required this.pluginRoot,
    this.version,
    this.sourceKind,
  });

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    final kind = json['source'] is Map ? (json['source'] as Map)['kind'] : null;
    return PluginInfo(
      pluginId: json['plugin_id'] as String,
      enabled: json['enabled'] as bool? ?? false,
      pluginRoot: json['plugin_root'] as String,
      version: json['version'] as String?,
      sourceKind: kind is String ? kind : null,
    );
  }

  final String pluginId;
  final bool enabled;

  /// Absolute path to the plugin's source directory on the host (e.g. where
  /// it was `herdr plugin link`ed from).
  final String pluginRoot;

  /// The plugin's declared version from its `herdr-plugin.toml`; absent for
  /// plugins that do not declare one.
  final String? version;

  /// How the plugin was installed, from the entry's `source.kind` (e.g.
  /// `github` for `herdr plugin install`, `link` for a local checkout);
  /// absent when herdr reports no recognisable source.
  final String? sourceKind;
}
