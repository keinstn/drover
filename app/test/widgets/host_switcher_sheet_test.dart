import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:drover/src/widgets/host_switcher_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _hostA = HostConfig(
  name: 'Work Mac',
  host: 'mac.example.com',
  user: 'dev',
  privateKeyPem: 'KEY',
  hostId: 'host-a',
);

const _hostB = HostConfig(
  host: 'pc.example.com',
  user: 'admin',
  privateKeyPem: 'KEY',
  hostId: 'host-b',
);

Widget _app({
  required ValueChanged<HostConfig> onSelect,
  required VoidCallback onManageHosts,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showHostSwitcherSheet(
              context,
              hosts: [_hostA, _hostB],
              activeHostId: 'host-a',
              onSelect: onSelect,
              onManageHosts: onManageHosts,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lists hosts, marks the active one, and selecting pops first', (
    tester,
  ) async {
    HostConfig? selected;
    await tester.pumpWidget(
      _app(onSelect: (h) => selected = h, onManageHosts: () {}),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Switch host'), findsOneWidget);
    expect(find.text('Work Mac'), findsOneWidget);
    expect(find.text('admin@pc.example.com'), findsOneWidget);
    // The active host gets the filled radio icon; the other stays outlined.
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    await tester.tap(find.text('admin@pc.example.com'));
    await tester.pumpAndSettle();

    expect(selected, same(_hostB));
    expect(find.text('Switch host'), findsNothing, reason: 'the sheet popped');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the manage row pops the sheet and calls onManageHosts', (
    tester,
  ) async {
    var manageCalls = 0;
    await tester.pumpWidget(
      _app(onSelect: (_) {}, onManageHosts: () => manageCalls++),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('host_switcher_manage')));
    await tester.pumpAndSettle();

    expect(manageCalls, 1);
    expect(find.text('Switch host'), findsNothing, reason: 'the sheet popped');

    await tester.pumpWidget(const SizedBox());
  });
}
