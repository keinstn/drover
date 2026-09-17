import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModeKey = 'theme_mode';
const _localeKey = 'locale';
const _notifyOnBlockedKey = 'notify_on_blocked';
const _notifyOnDoneKey = 'notify_on_done';
const _voiceAssistantKey = 'voice_assistant_enabled';
const _voiceConsentKey = 'voice_consent_accepted';

/// The user's app-level preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.locale,
    this.notifyOnBlocked = true,
    this.notifyOnDone = true,
    this.voiceAssistantEnabled = true,
    this.voiceConsentAccepted = false,
  });

  final ThemeMode themeMode;

  /// null = follow the device locale.
  final Locale? locale;

  /// Per-device push opt-ins. Both default to on, and registering writes them
  /// explicitly — which is what switches `done` on for this device, since the
  /// backend suppresses that kind for a device that has never sent the field.
  final bool notifyOnBlocked;
  final bool notifyOnDone;

  /// The off switch: shows the voice-assistant entry point on the herd
  /// screen. Not the opt-in — [voiceConsentAccepted] gates everything that
  /// leaves the device, and turning this off clears it.
  final bool voiceAssistantEnabled;

  /// Whether the user has accepted that a voice session streams their speech
  /// and agent context to Google (Gemini Live). False blocks the session
  /// before anything is recorded or sent — App Store guideline 5.1.2(i).
  final bool voiceConsentAccepted;
}

/// Persists [AppSettings] in shared_preferences.
class SettingsStore {
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      themeMode: _themeModeFrom(prefs.getString(_themeModeKey)),
      locale: _localeFrom(prefs.getString(_localeKey)),
      notifyOnBlocked: prefs.getBool(_notifyOnBlockedKey) ?? true,
      notifyOnDone: prefs.getBool(_notifyOnDoneKey) ?? true,
      voiceAssistantEnabled: prefs.getBool(_voiceAssistantKey) ?? true,
      voiceConsentAccepted: prefs.getBool(_voiceConsentKey) ?? false,
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

  Future<void> saveNotifyPreferences({
    required bool onBlocked,
    required bool onDone,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifyOnBlockedKey, onBlocked);
    await prefs.setBool(_notifyOnDoneKey, onDone);
  }

  Future<void> saveVoiceAssistantEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_voiceAssistantKey, enabled);
  }

  Future<void> saveVoiceConsentAccepted(bool accepted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_voiceConsentKey, accepted);
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
