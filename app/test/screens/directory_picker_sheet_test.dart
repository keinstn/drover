import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/screens/directory_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner({
    required this.listDirectoryImpl,
    required this.resolvePathImpl,
  });

  final Future<List<RemoteDirEntry>> Function(String path) listDirectoryImpl;
  Future<String> Function(String path) resolvePathImpl;

  @override
  Future<CommandResult> run(String command) async {
    throw UnimplementedError();
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) =>
      listDirectoryImpl(path);

  @override
  Future<String> resolvePath(String path) => resolvePathImpl(path);

  @override
  Future<void> dispose() async {}
}

const _tree = {
  '/home/dev': [
    RemoteDirEntry(name: 'projectA', isDirectory: true),
    RemoteDirEntry(name: 'projectB', isDirectory: true),
    RemoteDirEntry(name: '.config', isDirectory: true),
    RemoteDirEntry(name: 'notes.txt', isDirectory: false),
  ],
  '/home/dev/projectA': [RemoteDirEntry(name: 'sub', isDirectory: true)],
};

HerdrClient _buildClient() {
  final runner = FakeCommandRunner(
    resolvePathImpl: (path) async => path == '.' ? '/home/dev' : path,
    listDirectoryImpl: (path) async => _tree[path] ?? [],
  );
  return HerdrClient(runner);
}

void main() {
  testWidgets('starts at home showing visible dirs only', (tester) async {
    final client = _buildClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectoryPickerSheet(client: client),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('/home/dev'), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_projectA')), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_projectB')), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_.config')), findsNothing);
    expect(find.byKey(const ValueKey('dir_entry_notes.txt')), findsNothing);
  });

  testWidgets('tapping a directory navigates into it', (tester) async {
    final client = _buildClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectoryPickerSheet(client: client),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dir_entry_projectA')));
    await tester.pumpAndSettle();

    expect(find.text('/home/dev/projectA'), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_sub')), findsOneWidget);
  });

  testWidgets('the up button returns to the parent', (tester) async {
    final client = _buildClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectoryPickerSheet(client: client),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dir_entry_projectA')));
    await tester.pumpAndSettle();
    expect(find.text('/home/dev/projectA'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dir_picker_up')));
    await tester.pumpAndSettle();

    expect(find.text('/home/dev'), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_projectA')), findsOneWidget);
  });

  testWidgets('the show-hidden toggle reveals dotfiles', (tester) async {
    final client = _buildClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectoryPickerSheet(client: client),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dir_entry_.config')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('dir_picker_toggle_hidden')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dir_entry_.config')), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_notes.txt')), findsNothing);
  });

  testWidgets('tapping select pops the current absolute path', (tester) async {
    final client = _buildClient();
    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => DirectoryPickerSheet(client: client),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dir_entry_projectA')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dir_picker_select')));
    await tester.pumpAndSettle();

    expect(popped, '/home/dev/projectA');
  });

  testWidgets('a failed initial resolve shows an error with retry', (
    tester,
  ) async {
    final runner = FakeCommandRunner(
      resolvePathImpl: (path) async => throw Exception('ssh failed'),
      listDirectoryImpl: (path) async => _tree[path] ?? [],
    );
    final client = HerdrClient(runner);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectoryPickerSheet(client: client),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Exception: ssh failed'), findsOneWidget);
    final retryButton = find.widgetWithText(TextButton, 'Retry');
    expect(retryButton, findsOneWidget);

    runner.resolvePathImpl = (path) async => path == '.' ? '/home/dev' : path;
    await tester.tap(retryButton);
    await tester.pumpAndSettle();

    expect(find.text('/home/dev'), findsOneWidget);
    expect(find.byKey(const ValueKey('dir_entry_projectA')), findsOneWidget);
  });

  testWidgets('a trailing slash in initialPath does not produce //', (
    tester,
  ) async {
    final client = _buildClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectoryPickerSheet(client: client, initialPath: '/home/dev/'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('/home/dev'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dir_entry_projectA')));
    await tester.pumpAndSettle();

    expect(find.text('/home/dev/projectA'), findsOneWidget);
    expect(find.textContaining('//'), findsNothing);
  });
}
