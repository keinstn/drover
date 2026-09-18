import 'dart:async';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/firebase/apple_account.dart';
import 'package:drover/src/notifications/notify_plugin_version.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:drover/src/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({
  ThemeMode themeMode = ThemeMode.system,
  Locale? locale,
  bool notifyOnBlocked = true,
  bool notifyOnDone = true,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<Locale?>? onLocaleChanged,
  ValueChanged<bool>? onNotifyOnBlockedChanged,
  ValueChanged<bool>? onNotifyOnDoneChanged,
  bool voiceAssistantEnabled = false,
  ValueChanged<bool>? onVoiceAssistantChanged,
  bool appleSignedIn = false,
  Future<void> Function()? onSignInWithApple,
  VoidCallback? onManageHosts,
  VoidCallback? onEnterDemo,
  String? appVersion,
  List<Future<StaleNotifyPlugin?>>? staleNotifyPlugins,
}) {
  return MaterialApp(
    // The screen reads DroverColors, so the harness needs the real theme.
    theme: droverDarkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: _SettingsHost(
      themeMode: themeMode,
      locale: locale,
      notifyOnBlocked: notifyOnBlocked,
      notifyOnDone: notifyOnDone,
      onThemeModeChanged: onThemeModeChanged ?? (_) {},
      onLocaleChanged: onLocaleChanged ?? (_) {},
      onNotifyOnBlockedChanged: onNotifyOnBlockedChanged ?? (_) {},
      onNotifyOnDoneChanged: onNotifyOnDoneChanged ?? (_) {},
      voiceAssistantEnabled: voiceAssistantEnabled,
      onVoiceAssistantChanged: onVoiceAssistantChanged ?? (_) {},
      appleSignedIn: appleSignedIn,
      onSignInWithApple: onSignInWithApple ?? () async {},
      onManageHosts: onManageHosts ?? () {},
      onEnterDemo: onEnterDemo,
      appVersion: appVersion,
      staleNotifyPlugins: staleNotifyPlugins,
    ),
  );
}

/// Owns the switch values the way `main.dart` does. [SettingsScreen] is
/// stateless, so without a caller that rebuilds it a tap could never move the
/// rendered switch — the harness has to model that contract for the test to
/// mean anything.
class _SettingsHost extends StatefulWidget {
  const _SettingsHost({
    required this.themeMode,
    required this.locale,
    required this.notifyOnBlocked,
    required this.notifyOnDone,
    required this.onThemeModeChanged,
    required this.onLocaleChanged,
    required this.onNotifyOnBlockedChanged,
    required this.onNotifyOnDoneChanged,
    required this.voiceAssistantEnabled,
    required this.onVoiceAssistantChanged,
    required this.appleSignedIn,
    required this.onSignInWithApple,
    required this.onManageHosts,
    required this.onEnterDemo,
    required this.appVersion,
    required this.staleNotifyPlugins,
  });

  final ThemeMode themeMode;
  final Locale? locale;
  final bool notifyOnBlocked;
  final bool notifyOnDone;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<Locale?> onLocaleChanged;
  final ValueChanged<bool> onNotifyOnBlockedChanged;
  final ValueChanged<bool> onNotifyOnDoneChanged;
  final bool voiceAssistantEnabled;
  final ValueChanged<bool> onVoiceAssistantChanged;
  final bool appleSignedIn;
  final Future<void> Function() onSignInWithApple;
  final VoidCallback onManageHosts;
  final VoidCallback? onEnterDemo;
  final String? appVersion;
  final List<Future<StaleNotifyPlugin?>>? staleNotifyPlugins;

  @override
  State<_SettingsHost> createState() => _SettingsHostState();
}

class _SettingsHostState extends State<_SettingsHost> {
  late bool _notifyOnBlocked = widget.notifyOnBlocked;
  late bool _notifyOnDone = widget.notifyOnDone;
  late bool _voiceAssistantEnabled = widget.voiceAssistantEnabled;
  late bool _appleSignedIn = widget.appleSignedIn;

  @override
  Widget build(BuildContext context) {
    return SettingsScreen(
      themeMode: widget.themeMode,
      locale: widget.locale,
      notifyOnBlocked: _notifyOnBlocked,
      notifyOnDone: _notifyOnDone,
      onThemeModeChanged: widget.onThemeModeChanged,
      onLocaleChanged: widget.onLocaleChanged,
      onNotifyOnBlockedChanged: (value) {
        setState(() => _notifyOnBlocked = value);
        widget.onNotifyOnBlockedChanged(value);
      },
      onNotifyOnDoneChanged: (value) {
        setState(() => _notifyOnDone = value);
        widget.onNotifyOnDoneChanged(value);
      },
      voiceAssistantEnabled: _voiceAssistantEnabled,
      onVoiceAssistantChanged: (value) {
        setState(() => _voiceAssistantEnabled = value);
        widget.onVoiceAssistantChanged(value);
      },
      appleSignedIn: _appleSignedIn,
      // Models `main.dart`'s contract: the caller flips the flag only after
      // the link succeeds, and a throw leaves the row signed out.
      onSignInWithApple: () async {
        await widget.onSignInWithApple();
        setState(() => _appleSignedIn = true);
      },
      onManageHosts: widget.onManageHosts,
      onEnterDemo: widget.onEnterDemo,
      appVersion: widget.appVersion,
      staleNotifyPlugins: widget.staleNotifyPlugins,
    );
  }
}

/// The sections above push the account row past the fold, and a lazy
/// ListView never builds an off-screen row.
Future<void> _revealAccountRow(WidgetTester tester) =>
    tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings_account_tile')),
      200,
    );

bool _renderedSwitch(WidgetTester tester, String tileKey) => tester
    .widget<Switch>(
      find.descendant(
        of: find.byKey(ValueKey(tileKey)),
        matching: find.byType(Switch),
      ),
    )
    .value;

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

  testWidgets('the notification switches render their stored values', (
    tester,
  ) async {
    await tester.pumpWidget(_app(notifyOnBlocked: false, notifyOnDone: true));

    // Section headers render through droverLabelText, which uppercases
    // outside Japanese.
    expect(find.text('NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Blocked agents'), findsOneWidget);
    expect(find.text('Finished agents'), findsOneWidget);
    expect(_renderedSwitch(tester, 'settings_notify_blocked_tile'), isFalse);
    expect(_renderedSwitch(tester, 'settings_notify_done_tile'), isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a notification switch flips the rendered switch and '
      'reports the new value', (tester) async {
    final blockedChanges = <bool>[];
    await tester.pumpWidget(_app(onNotifyOnBlockedChanged: blockedChanges.add));

    await tester.tap(
      find.byKey(const ValueKey('settings_notify_blocked_tile')),
    );
    await tester.pumpAndSettle();

    expect(blockedChanges, [false]);
    expect(_renderedSwitch(tester, 'settings_notify_blocked_tile'), isFalse);
    // The other switch must not ride along.
    expect(_renderedSwitch(tester, 'settings_notify_done_tile'), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('settings_notify_blocked_tile')),
    );
    await tester.pumpAndSettle();

    expect(blockedChanges, [false, true]);
    expect(_renderedSwitch(tester, 'settings_notify_blocked_tile'), isTrue);

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
    // The assistant and notification sections push the footer past the fold;
    // a lazy ListView never builds an off-screen row.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings_version_tile')),
      200,
    );

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
    // The assistant and notification sections push the footer past the fold;
    // a lazy ListView never builds an off-screen row.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings_version_tile')),
      200,
    );
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
        of: find.byKey(const ValueKey('settings_hosts_tile')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    // The assistant and notification sections push the footer past the fold;
    // a lazy ListView never builds an off-screen row.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings_version_tile')),
      200,
    );
    expect(find.byKey(const ValueKey('settings_version_tile')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_version_tile')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stale notify plugin renders its row, title and subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(staleNotifyPlugins: [Future.value(_staleEntry)]),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(
      const ValueKey('settings_notify_plugin_update_tile_0'),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.text('Update the notification plugin'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.text('dev@stub-host is running 0.0.1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the row offers both reinstall commands verbatim, with '
      '~ expanded so the path is paste-safe', (tester) async {
    await tester.pumpWidget(
      _app(staleNotifyPlugins: [Future.value(_staleEntry)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('settings_notify_plugin_update_tile_0')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("\$HOME/'.local/bin/herdr' plugin uninstall drover.notify"),
      findsOneWidget,
    );
    expect(
      find.text(
        "\$HOME/'.local/bin/herdr' plugin install keinstn/drover-notify",
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'dev@stub-host is running drover-notify 0.0.1. Reinstall it on the '
        'Herdr host to get the latest notifications.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a probe that finds nothing stale renders no row', (
    tester,
  ) async {
    await tester.pumpWidget(_app(staleNotifyPlugins: [Future.value(null)]));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings_notify_plugin_update_tile_0')),
      findsNothing,
    );
    expect(find.text('Update the notification plugin'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed probe renders no row and does not surface the error — '
      'this is a diagnostic, not a feature the user asked for', (tester) async {
    await tester.pumpWidget(
      _app(
        staleNotifyPlugins: [
          Future<StaleNotifyPlugin?>(
            () => throw StateError('host unreachable'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings_notify_plugin_update_tile_0')),
      findsNothing,
    );
    expect(find.text('Update the notification plugin'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no future at all renders no row', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings_notify_plugin_update_tile_0')),
      findsNothing,
    );
    expect(find.text('Update the notification plugin'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a resolved probe renders its row while a sibling that never resolves '
    'stays pending — the reason for one future per host instead of '
    'Future.wait, which would hold the resolved row back too',
    (tester) async {
      final neverResolves = Completer<StaleNotifyPlugin?>();
      addTearDown(() => neverResolves.complete(null));

      await tester.pumpWidget(
        _app(
          staleNotifyPlugins: [Future.value(_staleEntry), neverResolves.future],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings_notify_plugin_update_tile_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings_notify_plugin_update_tile_1')),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('signed out, the account row offers Sign in with Apple', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await _revealAccountRow(tester);

    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_account_tile')),
        matching: find.text('Sign in with Apple'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signed in, the account row says so and renders no identifier', (
    tester,
  ) async {
    await tester.pumpWidget(_app(appleSignedIn: true));
    await _revealAccountRow(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_account_tile')),
        matching: find.text('Signed in with Apple'),
      ),
      findsOneWidget,
    );
    expect(find.text('Sign in with Apple'), findsNothing);
    // No scopes are requested, so no address can reach the screen. The
    // guard is cheap; the seam — a bool, not a user — is the real proof.
    expect(find.textContaining('@'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed sign-in is rendered on the row, which stays tappable', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        onSignInWithApple: () async {
          attempts++;
          throw Exception('the user dismissed the Apple sheet');
        },
      ),
    );
    await _revealAccountRow(tester);

    await tester.tap(find.byKey(const ValueKey('settings_account_tile')));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_account_tile')),
        matching: find.text("Couldn't sign in. Tap to try again."),
      ),
      findsOneWidget,
    );
    // Still the signed-out row: a failure must not read as an account.
    expect(find.text('Sign in with Apple'), findsOneWidget);
    expect(find.text('Signed in with Apple'), findsNothing);

    // And the retry the subtitle promises actually fires.
    await tester.tap(find.byKey(const ValueKey('settings_account_tile')));
    await tester.pumpAndSettle();
    expect(attempts, 2);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an Apple ID already attached to another account ends signed in: the '
    'link fails with credential-already-in-use and the older uid is adopted',
    (tester) async {
      var signedInWithProvider = false;
      await tester.pumpWidget(
        _app(
          onSignInWithApple: () => linkAppleAccount(
            // What a reinstalled device gets: its anonymous uid is new, but
            // the Apple ID still belongs to the uid from before.
            link: () async => throw FirebaseException(
              plugin: 'firebase_auth',
              code: 'credential-already-in-use',
            ),
            signIn: () async => signedInWithProvider = true,
          ),
        ),
      );
      await _revealAccountRow(tester);

      await tester.tap(find.byKey(const ValueKey('settings_account_tile')));
      await tester.pumpAndSettle();

      expect(signedInWithProvider, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings_account_tile')),
          matching: find.text('Signed in with Apple'),
        ),
        findsOneWidget,
      );
      expect(find.text("Couldn't sign in. Tap to try again."), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('any other link failure is reported, not swallowed', (
    tester,
  ) async {
    var signedInWithProvider = false;
    await tester.pumpWidget(
      _app(
        onSignInWithApple: () => linkAppleAccount(
          link: () async => throw FirebaseException(
            plugin: 'firebase_auth',
            code: 'network-request-failed',
          ),
          signIn: () async => signedInWithProvider = true,
        ),
      ),
    );
    await _revealAccountRow(tester);

    await tester.tap(find.byKey(const ValueKey('settings_account_tile')));
    await tester.pumpAndSettle();

    expect(signedInWithProvider, isFalse);
    expect(find.text("Couldn't sign in. Tap to try again."), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}

const _staleEntry = StaleNotifyPlugin(
  hostName: 'dev@stub-host',
  installedVersion: '0.0.1',
  // Tilde-prefixed on purpose: the rendered command must expand it.
  herdrBin: '~/.local/bin/herdr',
);
