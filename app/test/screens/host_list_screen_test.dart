import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:drover/src/screens/host_list_screen.dart';
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
  port: 2222,
  user: 'admin',
  privateKeyPem: 'KEY',
  hostId: 'host-b',
);

Widget _app({
  required List<HostConfig> hosts,
  String? activeHostId,
  Future<void> Function(HostConfig)? onSelect,
  VoidCallback? onAdd,
  void Function(HostConfig)? onEdit,
  Future<void> Function(HostConfig)? onDelete,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HostListScreen(
      hosts: hosts,
      activeHostId: activeHostId,
      onSelect: onSelect ?? (_) async {},
      onAdd: onAdd ?? () {},
      onEdit: onEdit ?? (_) {},
      onDelete: onDelete ?? (_) async {},
    ),
  );
}

Finder _tileIcon(String hostId, IconData icon) => find.descendant(
  of: find.byKey(ValueKey('host_tile_$hostId')),
  matching: find.byIcon(icon),
);

Future<void> _openTileMenu(WidgetTester tester, String hostId) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('host_tile_$hostId')),
      // The menu's value type is private to the screen, so find the button by
      // its default more_vert icon rather than by type.
      matching: find.byIcon(Icons.more_vert),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders each host with display name and marks the active one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(hosts: [_hostA, _hostB], activeHostId: 'host-a'),
    );

    // Named host shows the name; unnamed one falls back to user@host.
    expect(find.text('Work Mac'), findsOneWidget);
    expect(find.text('admin@pc.example.com'), findsOneWidget);
    // Subtitles always show user@host:port.
    expect(find.text('dev@mac.example.com:22'), findsOneWidget);
    expect(find.text('admin@pc.example.com:2222'), findsOneWidget);

    // Only the active host gets the filled radio icon.
    expect(_tileIcon('host-a', Icons.radio_button_checked), findsOneWidget);
    expect(_tileIcon('host-b', Icons.radio_button_unchecked), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a tile calls onSelect with that host', (tester) async {
    HostConfig? selected;
    await tester.pumpWidget(
      _app(
        hosts: [_hostA, _hostB],
        activeHostId: 'host-a',
        onSelect: (host) async => selected = host,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('host_tile_host-b')));
    await tester.pump();

    expect(selected, same(_hostB));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the add button calls onAdd', (tester) async {
    var addCalls = 0;
    await tester.pumpWidget(_app(hosts: [_hostA], onAdd: () => addCalls++));

    await tester.tap(find.byKey(const ValueKey('host_add_button')));
    await tester.pump();

    expect(addCalls, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tile menu edit action calls onEdit', (tester) async {
    HostConfig? edited;
    await tester.pumpWidget(
      _app(hosts: [_hostA, _hostB], onEdit: (host) => edited = host),
    );

    await _openTileMenu(tester, 'host-b');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(edited, same(_hostB));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('delete confirms, calls onDelete, and removes the tile', (
    tester,
  ) async {
    HostConfig? deleted;
    await tester.pumpWidget(
      _app(
        hosts: [_hostA, _hostB],
        activeHostId: 'host-a',
        onDelete: (host) async => deleted = host,
      ),
    );

    await _openTileMenu(tester, 'host-b');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // The confirm dialog names the host being deleted.
    expect(find.text('Delete host?'), findsOneWidget);
    expect(find.textContaining('admin@pc.example.com'), findsWidgets);
    expect(deleted, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, same(_hostB));
    expect(find.byKey(const ValueKey('host_tile_host-b')), findsNothing);
    expect(find.byKey(const ValueKey('host_tile_host-a')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling the delete dialog leaves the host untouched', (
    tester,
  ) async {
    var deleteCalls = 0;
    await tester.pumpWidget(
      _app(hosts: [_hostA, _hostB], onDelete: (_) async => deleteCalls++),
    );

    await _openTileMenu(tester, 'host-b');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 0);
    expect(find.byKey(const ValueKey('host_tile_host-b')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
