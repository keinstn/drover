import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({
  ThemeMode themeMode = ThemeMode.system,
  Locale? locale,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<Locale?>? onLocaleChanged,
  VoidCallback? onManageHosts,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SettingsScreen(
      themeMode: themeMode,
      locale: locale,
      onThemeModeChanged: onThemeModeChanged ?? (_) {},
      onLocaleChanged: onLocaleChanged ?? (_) {},
      onManageHosts: onManageHosts ?? () {},
    ),
  );
}

void main() {
  testWidgets('shows the current theme and language labels on the rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(themeMode: ThemeMode.dark, locale: const Locale('ja')),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_theme_tile')),
        matching: find.text('Dark'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_language_tile')),
        matching: find.text('日本語'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('defaults show System for both theme and language', (
    tester,
  ) async {
    await tester.pumpWidget(_app());

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_theme_tile')),
        matching: find.text('System'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_language_tile')),
        matching: find.text('System'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the theme row and picking Dark reports ThemeMode.dark', (
    tester,
  ) async {
    ThemeMode? picked;
    await tester.pumpWidget(_app(onThemeModeChanged: (mode) => picked = mode));

    await tester.tap(find.byKey(const ValueKey('settings_theme_tile')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings_theme_option_dark')));
    await tester.pumpAndSettle();

    expect(picked, ThemeMode.dark);
    expect(
      find.byKey(const ValueKey('settings_theme_option_dark')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the language row and picking 日本語 reports Locale(ja)', (
    tester,
  ) async {
    Locale? picked;
    await tester.pumpWidget(_app(onLocaleChanged: (locale) => picked = locale));

    await tester.tap(find.byKey(const ValueKey('settings_language_tile')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings_language_option_ja')));
    await tester.pumpAndSettle();

    expect(picked, const Locale('ja'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('picking System from the language sheet reports null', (
    tester,
  ) async {
    Locale? picked = const Locale('en');
    await tester.pumpWidget(
      _app(
        locale: const Locale('en'),
        onLocaleChanged: (locale) => picked = locale,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('settings_language_tile')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('settings_language_option_system')),
    );
    await tester.pumpAndSettle();

    expect(picked, isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the hosts row invokes onManageHosts', (tester) async {
    var manageCalls = 0;
    await tester.pumpWidget(_app(onManageHosts: () => manageCalls++));

    await tester.tap(find.byKey(const ValueKey('settings_hosts_tile')));
    await tester.pumpAndSettle();

    expect(manageCalls, 1);

    await tester.pumpWidget(const SizedBox());
  });
}
