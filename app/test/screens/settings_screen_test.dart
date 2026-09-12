import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({
  ThemeMode themeMode = ThemeMode.system,
  Locale? locale,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<Locale?>? onLocaleChanged,
  bool voiceAssistantEnabled = false,
  ValueChanged<bool>? onVoiceAssistantChanged,
  VoidCallback? onManageHosts,
  VoidCallback? onEnterDemo,
  String? appVersion,
}) {
  return MaterialApp(
    // The screen reads DroverColors, so the harness needs the real theme.
    theme: droverDarkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SettingsScreen(
      themeMode: themeMode,
      locale: locale,
      onThemeModeChanged: onThemeModeChanged ?? (_) {},
      onLocaleChanged: onLocaleChanged ?? (_) {},
      voiceAssistantEnabled: voiceAssistantEnabled,
      onVoiceAssistantChanged: onVoiceAssistantChanged ?? (_) {},
      onManageHosts: onManageHosts ?? () {},
      onEnterDemo: onEnterDemo,
      appVersion: appVersion,
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

  testWidgets('toggling the voice assistant switch reports the new value', (
    tester,
  ) async {
    bool? reported;
    await tester.pumpWidget(
      _app(onVoiceAssistantChanged: (enabled) => reported = enabled),
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings_voice_assistant_tile')),
      200,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings_voice_assistant_tile')),
    );
    await tester.pumpAndSettle();

    expect(reported, isTrue);
    // The switch sits under its own section header, not under Appearance.
    // Rendered through the label ramp, which uppercases outside Japanese.
    expect(find.text('ASSISTANT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the demo row shows and invokes onEnterDemo when one is given', (
    tester,
  ) async {
    var demoCalls = 0;
    await tester.pumpWidget(_app(onEnterDemo: () => demoCalls++));

    expect(find.text('Try the demo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings_demo_tile')));
    await tester.pumpAndSettle();

    expect(demoCalls, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the demo row is absent without an onEnterDemo callback — e.g. '
      'when settings was opened from inside the demo', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.byKey(const ValueKey('settings_demo_tile')), findsNothing);
    expect(find.text('Try the demo'), findsNothing);

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

  testWidgets('the version row renders the string it was given', (
    tester,
  ) async {
    await tester.pumpWidget(_app(appVersion: '9.9.9 (42)'));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_version_tile')),
        matching: find.text('9.9.9 (42)'),
      ),
      findsOneWidget,
    );
    // Paired with the null case below, which asserts findsNothing — without
    // this the negative assertion could pass vacuously.
    expect(find.byType(Divider), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the version row is absent without a version — an empty value '
      'would be worse than none', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.byKey(const ValueKey('settings_version_tile')), findsNothing);
    expect(find.text('Version'), findsNothing);
    // The divider lives inside the same guard, so it must not linger alone.
    expect(find.byType(Divider), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a blank version hides the row too — the guard is not null-only, '
      'because the plugin coerces a missing Info.plist key to an empty '
      'string instead of throwing', (tester) async {
    await tester.pumpWidget(_app(appVersion: ''));

    expect(find.byKey(const ValueKey('settings_version_tile')), findsNothing);
    expect(find.byType(Divider), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the version row puts the version on the clipboard', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(_app(appVersion: '9.9.9 (42)'));
    await tester.tap(find.byKey(const ValueKey('settings_version_tile')));
    await tester.pumpAndSettle();

    expect(copied, '9.9.9 (42)');
    expect(find.text('Version copied'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the version row carries no chevron, unlike the rows that '
      'navigate', (tester) async {
    await tester.pumpWidget(_app(appVersion: '9.9.9 (42)'));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_version_tile')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_hosts_tile')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });
}
