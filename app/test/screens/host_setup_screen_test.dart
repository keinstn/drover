import 'package:drover/src/models/host_config.dart';
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
    await tester.enterText(
      find.widgetWithText(TextFormField, 'User'),
      'dev',
    );
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
    expect(
      captured!.privateKeyPem,
      contains('BEGIN OPENSSH PRIVATE KEY'),
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
        home: HostSetupScreen(onSubmit: (config) async {}),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'User'),
      'dev',
    );
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
}
