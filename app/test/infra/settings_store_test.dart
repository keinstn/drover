import 'package:drover/src/infra/settings_store.dart';
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
