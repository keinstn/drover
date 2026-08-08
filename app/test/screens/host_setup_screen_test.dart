import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:drover/src/models/plugin_info.dart';
import 'package:drover/src/notifications/host_pairing.dart';
import 'package:drover/src/screens/host_setup_screen.dart';
import 'package:drover/src/widgets/text_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _samplePairing = PairingCode(
  code: 'PAIR-CODE-42',
  hostId: 'paired-host',
  completionUrl: 'https://example.com/completePairing',
);

const _samplePlugin = PluginInfo(
  pluginId: 'drover.notify',
  enabled: true,
  pluginRoot: '/checkout/drover-notify',
);

void main() {
  testWidgets('disables Scan Text for every host setup input', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(onSubmit: (config) async {}),
      ),
    );
    final editableTexts = tester.widgetList<EditableText>(
      find.byType(EditableText),
    );

    expect(editableTexts, hasLength(6));
    for (final editableText in editableTexts) {
      expect(
        editableText.contextMenuBuilder,
        same(noScanTextContextMenuBuilder),
      );
    }

    await tester.scrollUntilVisible(
      find.byType(ExpansionTile),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    final herdrBinEditableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(ExpansionTile),
        matching: find.byType(EditableText),
      ),
    );
    expect(
      herdrBinEditableText.contextMenuBuilder,
      same(noScanTextContextMenuBuilder),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders the demo entry when onEnterDemo is provided', (
    tester,
  ) async {
    var demoTaps = 0;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(
          onSubmit: (config) async {},
          onEnterDemo: () => demoTaps++,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('enter_demo_button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('enter_demo_button')));
    expect(demoTaps, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'omits the demo entry when onEnterDemo is null, as on the add/edit routes',
    (tester) async {
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

      expect(find.byKey(const ValueKey('enter_demo_button')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

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

  testWidgets('carries the optional name into the submitted config', (
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

    // Left blank, the name submits as null.
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump();
    expect(captured, isNotNull);
    expect(captured!.name, isNull);

    // A filled (padded) name submits trimmed.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name (optional)'),
      '  Work Mac  ',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump();
    expect(captured!.name, 'Work Mac');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejects an out-of-range port and blocks save', (tester) async {
    HostConfig? captured;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(onSubmit: (config) async => captured = config),
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Port'), '70000');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(captured, isNull);
    expect(
      find.text('Port must be a number between 1 and 65535'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejects a private key that is not a PEM block', (tester) async {
    HostConfig? captured;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(onSubmit: (config) async => captured = config),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'example.com',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'User'), 'dev');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Private key PEM'),
      'ssh-ed25519 AAAAC3NzaC1lZDI1... not a private key',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(captured, isNull);
    expect(
      find.textContaining("doesn't look like a private key"),
      findsOneWidget,
    );

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
            privateKeyPem:
                '-----BEGIN OPENSSH PRIVATE KEY-----\n'
                'abc\n'
                '-----END OPENSSH PRIVATE KEY-----',
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

  testWidgets(
    'the manual pairing dialog offers `plugin install` with no path to edit',
    (tester) async {
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
              herdrBin: '~/.local/bin/herdr',
              privateKeyPem:
                  '-----BEGIN OPENSSH PRIVATE KEY-----\n'
                  'abc\n'
                  '-----END OPENSSH PRIVATE KEY-----',
            ),
            onSubmit: (_) async {},
            onCreatePairingCode: (_) async => _samplePairing,
          ),
        ),
      );

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Create notification pairing code'),
      );
      await tester.pumpAndSettle();

      // The one-liner installs from GitHub, so nothing in it is a placeholder
      // the user has to replace by hand.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pairing_install_command')),
          matching: find.textContaining(
            'plugin install keinstn/drover-notify',
          ),
        ),
        findsOneWidget,
      );

      // Nothing anywhere in the dialog asks the user to substitute a path, and
      // the fabricated `node <path>/bin/setup.mjs` step is gone with it.
      expect(find.textContaining('/path/to/'), findsNothing);
      expect(find.textContaining('plugin link'), findsNothing);
      expect(find.textContaining('setup.mjs'), findsNothing);

      // The pairing code and completion URL stay, for pairing by hand.
      expect(find.text(_samplePairing.code), findsOneWidget);
      expect(find.text(_samplePairing.completionUrl), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('detected plugin: confirming auto-pairs and shows success', (
    tester,
  ) async {
    var autoPairCalls = 0;

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
          onSubmit: (config) async {},
          onCreatePairingCode: (_) async => _samplePairing,
          onDetectPlugin: (_) async => _samplePlugin,
          onAutoPair: (config, plugin, pairing) async {
            autoPairCalls++;
            expect(plugin.pluginRoot, _samplePlugin.pluginRoot);
            expect(pairing.code, _samplePairing.code);
          },
        ),
      ),
    );

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Create notification pairing code'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notification plugin detected'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
    await tester.pumpAndSettle();

    expect(autoPairCalls, 1);
    expect(find.text('Notifications paired'), findsOneWidget);
    expect(find.text('Pair the notification plugin'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'detected plugin: declining the confirmation falls back to the manual dialog',
    (tester) async {
      var autoPairCalls = 0;

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
            onSubmit: (config) async {},
            onCreatePairingCode: (_) async => _samplePairing,
            onDetectPlugin: (_) async => _samplePlugin,
            onAutoPair: (config, plugin, pairing) async {
              autoPairCalls++;
            },
          ),
        ),
      );

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Create notification pairing code'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(autoPairCalls, 0);
      expect(find.text('Pair the notification plugin'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'detected plugin: an auto-pair failure falls back to the manual dialog',
    (tester) async {
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
            onSubmit: (config) async {},
            onCreatePairingCode: (_) async => _samplePairing,
            onDetectPlugin: (_) async => _samplePlugin,
            onAutoPair: (config, plugin, pairing) async {
              throw StateError('node was not found on the host PATH.');
            },
          ),
        ),
      );

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Create notification pairing code'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
      await tester.pumpAndSettle();

      expect(find.text('Pair the notification plugin'), findsOneWidget);
      expect(find.textContaining(_samplePairing.code), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      // The auto-pair failure now surfaces via ErrorMessageView, whose headline
      // for an unknown-kind error is the raw technical detail.
      expect(
        find.textContaining('node was not found on the host PATH.'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('renders a successful connection test message in the done color', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: droverDarkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HostSetupScreen(
          onSubmit: (config) async {},
          onTest: (config) async => 'Connected: 2 agents',
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

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
    await tester.pumpAndSettle();

    final message = tester.widget<Text>(find.text('Connected: 2 agents'));
    expect(
      message.style?.color,
      droverDarkTheme.extension<DroverColors>()!.donePillFg,
    );

    await tester.pumpWidget(const SizedBox());
  });

  group('test-connection failure message', () {
    const pinnedHost = HostConfig(
      host: 'example.com',
      port: 22,
      user: 'dev',
      privateKeyPem:
          '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
      hostKeyFingerprint: 'SHA256:pinned',
    );

    testWidgets('a brand-new host (never connected) shows the generic message', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HostSetupScreen(
            onSubmit: (config) async {},
            onTest: (config) async => throw HerdrException(
              'transport',
              'x',
              cause: Exception('unreachable'),
            ),
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

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('address and port are correct'),
        findsOneWidget,
      );
    });

    testWidgets(
      're-testing a previously-connected host with the same address shows '
      'the lost-connection message',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HostSetupScreen(
              initial: pinnedHost,
              onSubmit: (config) async {},
              onTest: (config) async => throw HerdrException(
                'transport',
                'x',
                cause: Exception('unreachable'),
              ),
            ),
          ),
        );

        await tester.tap(
          find.widgetWithText(OutlinedButton, 'Test connection'),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Lost the connection'), findsOneWidget);
      },
    );

    testWidgets(
      'editing the host address before testing falls back to the generic '
      'message even though a fingerprint is pinned',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HostSetupScreen(
              initial: pinnedHost,
              onSubmit: (config) async {},
              onTest: (config) async => throw HerdrException(
                'transport',
                'x',
                cause: Exception('unreachable'),
              ),
            ),
          ),
        );

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Host'),
          'different-host.example.com',
        );
        await tester.tap(
          find.widgetWithText(OutlinedButton, 'Test connection'),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('address and port are correct'),
          findsOneWidget,
        );
      },
    );
  });
}
