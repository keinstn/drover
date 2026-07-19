import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../herdr/herdr_client.dart';
import '../models/remote_dir_entry.dart';

/// Full-page picker for choosing a remote directory (e.g. as an agent's
/// working directory). Starts browsing at [initialPath] if it's a non-empty
/// absolute path, else at the login home directory.
class DirectoryPickerSheet extends StatefulWidget {
  const DirectoryPickerSheet({
    super.key,
    required this.client,
    this.initialPath,
  });

  final HerdrClient client;
  final String? initialPath;

  @override
  State<DirectoryPickerSheet> createState() => _DirectoryPickerSheetState();
}

class _DirectoryPickerSheetState extends State<DirectoryPickerSheet> {
  String? _currentPath;
  Future<List<RemoteDirEntry>>? _entriesFuture;
  bool _showHidden = false;
  Object? _initError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final initial = widget.initialPath;
      final path =
          (initial != null && initial.isNotEmpty && initial.startsWith('/'))
          ? _stripTrailingSlash(initial)
          : await widget.client.resolvePath('.');
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        _initError = null;
        _load();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = e;
      });
    }
  }

  /// Strips a single trailing '/' from [path], leaving the root '/' as-is.
  String _stripTrailingSlash(String path) {
    if (path == '/' || !path.endsWith('/')) return path;
    return path.substring(0, path.length - 1);
  }

  void _load() {
    final path = _currentPath;
    if (path == null) return;
    _entriesFuture = widget.client.listDirectory(path).then((entries) {
      final dirs = entries.where((e) => e.isDirectory).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return dirs;
    });
  }

  void _navigateTo(String path) {
    setState(() {
      _currentPath = path;
      _load();
    });
  }

  String _joinPath(String base, String name) =>
      base == '/' ? '/$name' : '$base/$name';

  /// Parent of [path], or null if [path] is already the root.
  String? _parentPath(String path) {
    if (path == '/') return null;
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final path = _currentPath;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dirPickerTitle),
        actions: [
          IconButton(
            key: const ValueKey('dir_picker_toggle_hidden'),
            icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off),
            tooltip: l10n.dirPickerShowHidden,
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
        ],
      ),
      body: path == null
          ? (_initError == null
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _initError.toString(),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        TextButton(
                          onPressed: _init,
                          child: Text(l10n.commonRetry),
                        ),
                      ],
                    ),
                  ))
          : Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey('dir_picker_up'),
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: l10n.dirPickerParent,
                      onPressed: () {
                        final parent = _parentPath(path);
                        if (parent != null) _navigateTo(parent);
                      },
                    ),
                    Expanded(
                      child: Text(
                        path,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(child: _buildList(path)),
              ],
            ),
      bottomNavigationBar: path == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('dir_picker_select'),
                    onPressed: () => Navigator.pop(context, path),
                    child: Text(l10n.dirPickerUse),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildList(String path) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<List<RemoteDirEntry>>(
      future: _entriesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  snapshot.error.toString(),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: () => setState(_load),
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          );
        }
        final entries = (snapshot.data ?? [])
            .where((e) => _showHidden || !e.name.startsWith('.'))
            .toList();
        if (entries.isEmpty) {
          return Center(child: Text(l10n.dirPickerEmpty));
        }
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return ListTile(
              key: ValueKey('dir_entry_${entry.name}'),
              leading: const Icon(Icons.folder),
              title: Text(entry.name),
              onTap: () => _navigateTo(_joinPath(path, entry.name)),
            );
          },
        );
      },
    );
  }
}
