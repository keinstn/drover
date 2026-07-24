import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/host_config.dart';

/// Bottom sheet for quickly switching between stored hosts. Tapping a host
/// (or the manage row) pops the sheet first, then invokes the callback — the
/// caller owns whatever reconnection or navigation follows.
Future<void> showHostSwitcherSheet(
  BuildContext context, {
  required List<HostConfig> hosts,
  required String? activeHostId,
  required ValueChanged<HostConfig> onSelect,
  required VoidCallback onManageHosts,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => _HostSwitcherSheet(
      hosts: hosts,
      activeHostId: activeHostId,
      onSelect: onSelect,
      onManageHosts: onManageHosts,
    ),
  );
}

class _HostSwitcherSheet extends StatelessWidget {
  const _HostSwitcherSheet({
    required this.hosts,
    required this.activeHostId,
    required this.onSelect,
    required this.onManageHosts,
  });

  final List<HostConfig> hosts;
  final String? activeHostId;
  final ValueChanged<HostConfig> onSelect;
  final VoidCallback onManageHosts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    // Self-decorate: the rounded top + grab handle live here rather than at
    // the call site, same as LaunchAgentSheet.
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Material(
        color: scheme.surfaceContainer,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    l10n.hostSwitcherTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 8),
                // Host rows scroll when they outgrow the sheet; the header
                // above and the manage row below stay pinned.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final host in hosts)
                          ListTile(
                            leading: Icon(
                              host.hostId != null && host.hostId == activeHostId
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color:
                                  host.hostId != null &&
                                      host.hostId == activeHostId
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            title: Text(
                              host.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              onSelect(host);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('host_switcher_manage'),
                  leading: const Icon(Icons.settings),
                  title: Text(l10n.hostSwitcherManage),
                  onTap: () {
                    Navigator.pop(context);
                    onManageHosts();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
