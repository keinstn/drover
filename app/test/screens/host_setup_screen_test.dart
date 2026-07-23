import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:drover/src/notifications/host_pairing.dart';
import 'package:drover/src/screens/host_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('submits a HostConfig with defaults for port and herdrBin', (
    tester,
  ) async {
    HostConfig? captured;

    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(
          onSubmit: (config) async {
            captured = config;
          },
        ),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'example.com',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'User'), 'dev');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Private key PEM'),
      '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.host, 'example.com');
    expect(captured!.user, 'dev');
    expect(captured!.port, 22);
    expect(captured!.herdrBin, '~/.local/bin/herdr');
    expect(captured!.privateKeyPem, contains('BEGIN OPENSSH PRIVATE KEY'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hides the reset control during first-run setup', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(onSubmit: (config) async {}),
      ),
    );

    expect(find.text('Reset host'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reset host asks for confirmation before clearing', (
    tester,
  ) async {
    var resetCalls = 0;

    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(
          initial: const HostConfig(
            host: 'example.com',
            port: 22,
            user: 'dev',
            privateKeyPem: 'KEY',
          ),
          onSubmit: (config) async {},
          onReset: () async {
            resetCalls++;
          },
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Reset host'));
    await tester.pumpAndSettle();

    // Cancelling leaves the config untouched.
    expect(find.text('Reset host?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(resetCalls, 0);

    // Confirming invokes onReset.
    await tester.tap(find.widgetWithText(TextButton, 'Reset host'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(resetCalls, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('re-enables Save after a successful submit', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(onSubmit: (config) async {}),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'example.com',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'User'), 'dev');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Private key PEM'),
      '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump();

    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(saveButton.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps a newly paired host ID when saving settings', (
    tester,
  ) async {
    HostConfig? captured;

    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(
          initial: const HostConfig(
            host: 'example.com',
            user: 'dev',
            privateKeyPem: 'KEY',
          ),
          onSubmit: (config) async {
            captured = config;
          },
          onCreatePairingCode: (_) async => const PairingCode(
            code: 'code',
            hostId: 'paired-host',
            completionUrl: 'https://example.com/completePairing',
          ),
        ),
      ),
    );

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Create notification pairing code'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(captured?.hostId, 'paired-host');

    await tester.pumpWidget(const SizedBox());
  });
}
