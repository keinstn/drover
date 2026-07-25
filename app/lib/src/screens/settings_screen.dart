import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// App-level settings: theme, language, and a shortcut into host management.
/// Takes plain [ThemeMode]/[Locale] values rather than reading a settings
/// store directly — the caller owns persistence and rebuilds this screen
/// (and the rest of the app) when either changes.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.locale,
    required this.onThemeModeChanged,
    required this.onLocaleChanged,
    required this.onManageHosts,
  });

  final ThemeMode themeMode;

  /// null = follow the device locale.
  final Locale? locale;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<Locale?> onLocaleChanged;
  final VoidCallback onManageHosts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          ListTile(
            key: const ValueKey('settings_hosts_tile'),
            leading: const Icon(Icons.dns),
            title: Text(l10n.hostListTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: onManageHosts,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.settingsAppearance,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: scheme.primary),
            ),
          ),
          ListTile(
            key: const ValueKey('settings_theme_tile'),
            leading: const Icon(Icons.brightness_6),
            title: Text(l10n.settingsTheme),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _themeModeLabel(l10n, themeMode),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _showThemeSheet(
              context,
              current: themeMode,
              onSelect: onThemeModeChanged,
            ),
          ),
          ListTile(
            key: const ValueKey('settings_language_tile'),
            leading: const Icon(Icons.language),
            title: Text(l10n.settingsLanguage),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _localeLabel(l10n, locale),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _showLanguageSheet(
              context,
              current: locale,
              onSelect: onLocaleChanged,
            ),
          ),
        ],
      ),
    );
  }
}

String _themeModeLabel(AppLocalizations l10n, ThemeMode mode) => switch (mode) {
  ThemeMode.system => l10n.settingsThemeSystem,
  ThemeMode.light => l10n.settingsThemeLight,
  ThemeMode.dark => l10n.settingsThemeDark,
};

// The system option is localized; 日本語/English are hardcoded literals (not
// l10n strings) so a user who picked a language they can't read can still
// find their way back to the row that lets them change it.
String _localeLabel(AppLocalizations l10n, Locale? locale) =>
    switch (locale?.languageCode) {
      'ja' => '日本語',
      'en' => 'English',
      _ => l10n.settingsLanguageSystem,
    };

Future<void> _showThemeSheet(
  BuildContext context, {
  required ThemeMode current,
  required ValueChanged<ThemeMode> onSelect,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => _OptionSheet(
      title: l10n.settingsTheme,
      options: [
        _option(
          context,
          key: const ValueKey('settings_theme_option_system'),
          label: l10n.settingsThemeSystem,
          selected: current == ThemeMode.system,
          onTap: () {
            Navigator.pop(context);
            onSelect(ThemeMode.system);
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_theme_option_light'),
          label: l10n.settingsThemeLight,
          selected: current == ThemeMode.light,
          onTap: () {
            Navigator.pop(context);
            onSelect(ThemeMode.light);
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_theme_option_dark'),
          label: l10n.settingsThemeDark,
          selected: current == ThemeMode.dark,
          onTap: () {
            Navigator.pop(context);
            onSelect(ThemeMode.dark);
          },
        ),
      ],
    ),
  );
}

Future<void> _showLanguageSheet(
  BuildContext context, {
  required Locale? current,
  required ValueChanged<Locale?> onSelect,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => _OptionSheet(
      title: l10n.settingsLanguage,
      options: [
        _option(
          context,
          key: const ValueKey('settings_language_option_system'),
          label: l10n.settingsLanguageSystem,
          selected: current == null,
          onTap: () {
            Navigator.pop(context);
            onSelect(null);
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_language_option_ja'),
          label: '日本語',
          selected: current?.languageCode == 'ja',
          onTap: () {
            Navigator.pop(context);
            onSelect(const Locale('ja'));
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_language_option_en'),
          label: 'English',
          selected: current?.languageCode == 'en',
          onTap: () {
            Navigator.pop(context);
            onSelect(const Locale('en'));
          },
        ),
      ],
    ),
  );
}

/// Shared bottom-sheet chrome for a radio-style option list: rounded top +
/// grab handle + `titleLarge` header, same visual pattern as
/// `host_switcher_sheet.dart`. [options] are pre-built rows (see [_option]);
/// each already pops the sheet before invoking its own callback.
class _OptionSheet extends StatelessWidget {
  const _OptionSheet({required this.title, required this.options});

  final String title;
  final List<Widget> options;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Material(
        color: scheme.surfaceContainer,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 8),
                ...options,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One radio-style row shared by both sheets.
Widget _option(
  BuildContext context, {
  required Key key,
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  final scheme = Theme.of(context).colorScheme;
  return ListTile(
    key: key,
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: selected ? scheme.primary : scheme.onSurfaceVariant,
    ),
    title: Text(label),
    onTap: onTap,
  );
}
