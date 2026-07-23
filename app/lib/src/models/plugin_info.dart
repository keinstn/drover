/// A Herdr plugin entry from `herdr plugin list --json`.
class PluginInfo {
  const PluginInfo({
    required this.pluginId,
    required this.enabled,
    required this.pluginRoot,
  });

  factory PluginInfo.fromJson(Map<String, dynamic> json) => PluginInfo(
    pluginId: json['plugin_id'] as String,
    enabled: json['enabled'] as bool? ?? false,
    pluginRoot: json['plugin_root'] as String,
  );

  final String pluginId;
  final bool enabled;

  /// Absolute path to the plugin's source directory on the host (e.g. where
  /// it was `herdr plugin link`ed from).
  final String pluginRoot;
}
