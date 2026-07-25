import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModeKey = 'theme_mode';
const _localeKey = 'locale';

/// The user's app-level preferences.
class AppSettings {
  const AppSettings({this.themeMode = ThemeMode.system, this.locale});

  final ThemeMode themeMode;

  /// null = follow the device locale.
  final Locale? locale;
}

/// Persists [AppSettings] in shared_preferences.
class SettingsStore {
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      themeMode: _themeModeFrom(prefs.getString(_themeModeKey)),
      locale: _localeFrom(prefs.getString(_localeKey)),
    );
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  Future<void> saveLocale(Locale? locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, locale?.languageCode ?? 'system');
  }

  // Unrecognised/missing values fall back to the default rather than
  // throwing — a corrupt pref must not brick startup.
  ThemeMode _themeModeFrom(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  // Only 'en'/'ja' (the app's supportedLocales) are valid; anything else,
  // including 'system', loads as null (follow the device locale).
  Locale? _localeFrom(String? value) => switch (value) {
    'en' => const Locale('en'),
    'ja' => const Locale('ja'),
    _ => null,
  };
}
