import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/host_config.dart';

enum _HostMenuAction { edit, delete }

/// Manages the stored hosts: lists every saved [HostConfig], marks the active
/// one, and offers add/edit/delete. The caller owns navigation and storage —
/// tapping a tile only awaits [HostListScreen.onSelect], and a confirmed
/// delete awaits [HostListScreen.onDelete] before dropping the tile from the
/// screen's own local copy of [HostListScreen.hosts].
class HostListScreen extends StatefulWidget {
  const HostListScreen({
    super.key,
    required this.hosts,
    required this.activeHostId,
    required this.onSelect,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  /// Initial snapshot of the stored hosts.
  final List<HostConfig> hosts;
  final String? activeHostId;
  final Future<void> Function(HostConfig) onSelect;
  final VoidCallback onAdd;
  final void Function(HostConfig) onEdit;
  final Future<void> Function(HostConfig) onDelete;

  @override
  State<HostListScreen> createState() => _HostListScreenState();
}

class _HostListScreenState extends State<HostListScreen> {
  late final List<HostConfig> _hosts;

  @override
  void initState() {
    super.initState();
    _hosts = [...widget.hosts];
  }

  Future<void> _confirmAndDelete(HostConfig host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return AlertDialog(
          title: Text(l10n.hostDeleteDialogTitle),
          content: Text(l10n.hostDeleteDialogBody(host.displayName)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.commonDelete),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await widget.onDelete(host);
    if (!mounted) return;
    setState(() => _hosts.remove(host));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.hostListTitle),
        actions: [
          IconButton(
            key: const ValueKey('host_add_button'),
            icon: const Icon(Icons.add),
            onPressed: widget.onAdd,
          ),
        ],
      ),
      body: ListView(
        children: [for (final host in _hosts) _hostTile(context, l10n, host)],
      ),
    );
  }

  Widget _hostTile(
    BuildContext context,
    AppLocalizations l10n,
    HostConfig host,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isActive = host.hostId != null && host.hostId == widget.activeHostId;
    return ListTile(
      key: ValueKey('host_tile_${host.hostId}'),
      leading: Icon(
        isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: isActive ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        host.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${host.user}@${host.host}:${host.port}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<_HostMenuAction>(
        onSelected: (action) {
          switch (action) {
            case _HostMenuAction.edit:
              widget.onEdit(host);
            case _HostMenuAction.delete:
              _confirmAndDelete(host);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _HostMenuAction.edit,
            child: Text(l10n.commonEdit),
          ),
          PopupMenuItem(
            value: _HostMenuAction.delete,
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
      onTap: () => widget.onSelect(host),
    );
  }
}
