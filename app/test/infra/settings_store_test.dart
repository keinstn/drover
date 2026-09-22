import 'package:drover/src/infra/settings_store.dart';
import 'package:drover/src/voice/voice_consent_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SettingsStore store;

  setUp(() {
    store = SettingsStore();
  });

  test('load() on empty storage returns defaults', () async {
    SharedPreferences.setMockInitialValues({});

    final settings = await store.load();
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.locale, isNull);
    expect(settings.notifyOnBlocked, isTrue);
    expect(settings.notifyOnDone, isTrue);
    expect(settings.voiceAssistantEnabled, isTrue);
    expect(settings.voiceConsentVersion, 0);
    expect(settings.voicePaidInterest, isFalse);
  });

  test('saveVoicePaidInterest()/load() survives a restart', () async {
    // The only record this device has that it already sent its tap: the
    // server counts them and keeps no uid, so a lost flag is a second tap
    // from the same person.
    SharedPreferences.setMockInitialValues({});
    await store.saveVoicePaidInterest();

    expect((await store.load()).voicePaidInterest, isTrue);
  });

  test('a stored voice-assistant opt-out survives the on-by-default', () async {
    SharedPreferences.setMockInitialValues({});
    await store.saveVoiceAssistantEnabled(false);

    expect((await store.load()).voiceAssistantEnabled, isFalse);
  });

  test('saveVoiceConsentVersion()/load() roundtrips', () async {
    SharedPreferences.setMockInitialValues({});
    await store.saveVoiceConsentVersion(kVoiceConsentVersion);

    expect((await store.load()).voiceConsentVersion, kVoiceConsentVersion);
  });

  test('an accept of the old disclosure does not read as consent', () async {
    // What installs from before the consent was versioned carry. The copy has
    // changed since, so the only safe reading of it is "not yet accepted".
    SharedPreferences.setMockInitialValues({'voice_consent_accepted': true});

    expect((await store.load()).voiceConsentVersion, 0);
  });

  test('saveNotifyPreferences()/load() roundtrips both switches', () async {
    SharedPreferences.setMockInitialValues({});
    await store.saveNotifyPreferences(onBlocked: false, onDone: true);

    var settings = await store.load();
    expect(settings.notifyOnBlocked, isFalse);
    expect(settings.notifyOnDone, isTrue);

    await store.saveNotifyPreferences(onBlocked: true, onDone: false);

    settings = await store.load();
    expect(settings.notifyOnBlocked, isTrue);
    expect(settings.notifyOnDone, isFalse);
  });

  test('saveThemeMode()/load() roundtrips each theme mode', () async {
    for (final mode in ThemeMode.values) {
      SharedPreferences.setMockInitialValues({});
      await store.saveThemeMode(mode);

      final settings = await store.load();
      expect(settings.themeMode, mode);
    }
  });

  test('saveLocale()/load() roundtrips each supported locale', () async {
    for (final locale in [const Locale('en'), const Locale('ja')]) {
      SharedPreferences.setMockInitialValues({});
      await store.saveLocale(locale);

      final settings = await store.load();
      expect(settings.locale, locale);
    }
  });

  test('saveLocale(null) persists as system and loads as null', () async {
    SharedPreferences.setMockInitialValues({});
    await store.saveLocale(const Locale('ja'));
    await store.saveLocale(null);

    final settings = await store.load();
    expect(settings.locale, isNull);
  });

  test('unknown stored theme mode falls back to system', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'sepia'});

    final settings = await store.load();
    expect(settings.themeMode, ThemeMode.system);
  });

  test('unknown stored locale falls back to null', () async {
    SharedPreferences.setMockInitialValues({'locale': 'fr'});

    final settings = await store.load();
    expect(settings.locale, isNull);
  });
}
