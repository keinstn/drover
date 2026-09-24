import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModeKey = 'theme_mode';
const _localeKey = 'locale';
const _notifyOnBlockedKey = 'notify_on_blocked';
const _notifyOnDoneKey = 'notify_on_done';
const _voiceAssistantKey = 'voice_assistant_enabled';
const _voiceConsentVersionKey = 'voice_consent_version';
const _voicePaidInterestKey = 'voice_paid_interest';

/// The user's app-level preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.locale,
    this.notifyOnBlocked = true,
    this.notifyOnDone = true,
    this.voiceAssistantEnabled = true,
    this.voiceConsentVersion = 0,
    this.voicePaidInterest = false,
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
  /// screen. Not the opt-in — [voiceConsentVersion] gates everything that
  /// leaves the device, and turning this off clears it.
  final bool voiceAssistantEnabled;

  /// Which version of the voice disclosure the user accepted; 0 is "none
  /// yet". Anything below `kVoiceConsentVersion` blocks the session before
  /// anything is recorded or sent and puts the sheet back up — App Store
  /// guideline 5.1.2(i) wants the disclosure the user agreed to to be the
  /// one describing what the app now does. A version rather than a flag
  /// because the copy changes: installs carrying the old `bool` under the
  /// old key read 0 here and are asked again, which is the safe direction.
  final int voiceConsentVersion;

  /// Whether this device has already told the developer its owner would pay
  /// to keep using the voice assistant.
  ///
  /// Here rather than on the server because the server stores no uid against
  /// that tap — only a total — so there is nowhere else for it to live. That
  /// makes it a property of the install: a reinstall, or the same person on a
  /// second device, offers the tap again. Deliberate, and the reason the
  /// count is read as taps rather than people.
  final bool voicePaidInterest;
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
      voiceConsentVersion: prefs.getInt(_voiceConsentVersionKey) ?? 0,
      voicePaidInterest: prefs.getBool(_voicePaidInterestKey) ?? false,
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

  /// Records the accepted disclosure version, or 0 to revoke.
  Future<void> saveVoiceConsentVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_voiceConsentVersionKey, version);
  }

  /// Remembers that this device has sent the paid-interest tap. One way
  /// only: there is nothing to take back, because nothing identifies the
  /// sender on the other end.
  Future<void> saveVoicePaidInterest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_voicePaidInterestKey, true);
  }

  // Unrecognised/missing values fall back to the default rather than
  // throwing — a corrupt pref must not brick startup.
  ThemeMode _themeModeFrom(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  // Only the app's supportedLocales are valid; anything else, including
  // 'system', loads as null (follow the device locale).
  Locale? _localeFrom(String? value) => switch (value) {
    'en' => const Locale('en'),
    'ja' => const Locale('ja'),
    'zh' => const Locale('zh'),
    _ => null,
  };
}
