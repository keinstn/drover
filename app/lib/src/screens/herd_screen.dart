import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../agents/agent_native_history.dart';
import '../app_theme.dart';
import '../herdr/herdr_client.dart';
import '../i18n/status_label.dart';
import '../models/agent_info.dart';
import '../speech/speech_input.dart';
import '../utils/path.dart';
import '../widgets/text_context_menu.dart';
import '../widgets/top_toast.dart';
import 'agent_screen.dart';
import 'launch_agent_sheet.dart';

const _statusOrder = <AgentStatus, int>{
  AgentStatus.blocked: 0,
  AgentStatus.working: 1,
  AgentStatus.unknown: 2,
  AgentStatus.idle: 3,
  AgentStatus.done: 4,
};

Color statusColor(AgentStatus status) {
  switch (status) {
    case AgentStatus.blocked:
      return statusBlocked;
    case AgentStatus.working:
      return statusWorking;
    case AgentStatus.idle:
      return statusIdle;
    case AgentStatus.done:
      return statusDone;
    case AgentStatus.unknown:
      return statusUnknown;
  }
}

/// The main screen: a live list of every agent Herdr knows about, grouped by
/// workspace and polled every [pollInterval].
class HerdScreen extends StatefulWidget {
  const HerdScreen({
    super.key,
    required this.client,
    required this.onOpenSettings,
    this.speechInput,
    this.pollInterval = const Duration(seconds: 2),
  });

  final HerdrClient client;
  final VoidCallback onOpenSettings;
  final SpeechInput? speechInput;
  final Duration pollInterval;

  @override
  State<HerdScreen> createState() => _HerdScreenState();
}

class _HerdScreenState extends State<HerdScreen> {
  List<AgentInfo> _agents = [];
  String? _error;
  String? _workspaceLabelsError;
  bool _loading = false;
  bool _workspaceLabelsLoading = false;
  bool _workspaceLabelsFailed = false;
  Timer? _timer;
  final _previousStatus = <String, AgentStatus>{};
  Map<String, String> _workspaceLabels = {};
  final _stoppingPaneIds = <String>{};
  // One `NativeTranscriptHistory` per pane, owned by this screen (not
  // global/static state) and injected into `AgentScreen` on open so
  // reopening the same pane resumes from its already-loaded window/offset
  // state instead of re-fetching from scratch. Each instance still
  // re-resolves/resets itself when that pane's agent session identity
  // changes (see `NativeTranscriptHistory`); entries for panes no longer
  // reported by the herd are dropped in [_load].
  final _nativeHistoryCache = <String, NativeTranscriptHistory>{};

  @override
  void initState() {
    super.initState();
    _load();
    _loadWorkspaceLabels();
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Starts (or restarts) the periodic [_load] poll. A no-op if already
  /// running: [_load] itself is guarded by [_loading], so calling this twice
  /// in a row would otherwise leak the original [Timer].
  void _startPolling() {
    _timer ??= Timer.periodic(widget.pollInterval, (_) => _load());
  }

  /// Stops the periodic poll without touching an in-flight [_load] call,
  /// which remains safe to finish on its own (it checks [mounted] and guards
  /// re-entrancy via [_loading]).
  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// The cached native-history/loader instance for [paneId], creating one on
  /// first use.
  NativeTranscriptHistory _nativeHistoryFor(String paneId) =>
      _nativeHistoryCache.putIfAbsent(
        paneId,
        () => NativeTranscriptHistory(widget.client.runner),
      );

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final agents = await widget.client.listAgents();
      _checkBlockedTransitions(agents);
      if (!mounted) return;
      setState(() {
        _agents = agents;
        _error = null;
      });
      // Drop any cached history for a pane the herd no longer reports (the
      // agent stopped/exited), so the cache doesn't grow unboundedly.
      final panes = agents.map((agent) => agent.paneId).toSet();
      _nativeHistoryCache.removeWhere((paneId, _) => !panes.contains(paneId));
      if (!_workspaceLabelsFailed &&
          agents.any(
            (agent) => !_workspaceLabels.containsKey(agent.workspaceId),
          )) {
        _loadWorkspaceLabels();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadWorkspaceLabels() async {
    if (_workspaceLabelsLoading) return;
    _workspaceLabelsLoading = true;
    try {
      final workspaces = await widget.client.listWorkspaces();
      if (!mounted) return;
      setState(() {
        _workspaceLabelsFailed = false;
        _workspaceLabelsError = null;
        _workspaceLabels = {
          for (final workspace in workspaces)
            workspace.workspaceId: workspace.label.isEmpty
                ? workspace.workspaceId
                : workspace.label,
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _workspaceLabelsFailed = true;
        _workspaceLabelsError = e.toString();
      });
    } finally {
      _workspaceLabelsLoading = false;
    }
  }

  void _retryWorkspaceLabels() {
    setState(() {
      _workspaceLabelsFailed = false;
      _workspaceLabelsError = null;
    });
    _loadWorkspaceLabels();
  }

  String _workspaceLabel(String workspaceId) =>
      _workspaceLabels[workspaceId] ?? workspaceId;

  String _agentDisplayName(AgentInfo agent) =>
      agent.sessionTitle ?? agent.name ?? agent.agent ?? agent.paneId;

  String _agentMetadata(AgentInfo agent) {
    final cwd = agent.foregroundCwd ?? agent.cwd;
    final agentType = agent.agent ?? 'agent';
    return '$agentType · ${lastPathSegment(cwd)}';
  }

  void _checkBlockedTransitions(List<AgentInfo> agents) {
    for (final agent in agents) {
      final previous = _previousStatus[agent.paneId];
      final seenBefore = _previousStatus.containsKey(agent.paneId);
      if (seenBefore &&
          previous != AgentStatus.blocked &&
          agent.status == AgentStatus.blocked) {
        HapticFeedback.heavyImpact();
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          showTopToast(
            context,
            l10n.herdAgentBlocked(_agentDisplayName(agent)),
          );
        }
      }
      _previousStatus[agent.paneId] = agent.status;
    }
  }

  List<String> _distinctCwds() {
    final seen = <String>{};
    final cwds = <String>[];
    for (final agent in _agents) {
      final cwd = agent.foregroundCwd ?? agent.cwd;
      if (seen.add(cwd)) cwds.add(cwd);
    }
    return cwds;
  }

  Future<void> _openLaunchSheet() async {
    final launched = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: LaunchAgentSheet(
          client: widget.client,
          existingCwds: _distinctCwds(),
        ),
      ),
    );
    if (launched == true) _load();
  }

  /// Pushes the detail screen for [agent], suspending the periodic
  /// [_load]/[listAgents] poll for the duration of that route. `HerdScreen`
  /// stays mounted (and visible) behind the pushed route, so without this its
  /// 2-second poll would keep contending for the single mutex-serialized SSH
  /// channel that `AgentScreen` needs for its own (now progressive) loading.
  /// Polling resumes, and an immediate refresh is kicked off, once the route
  /// is popped.
  Future<void> _openAgentScreen(AgentInfo agent) async {
    _stopPolling();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentScreen(
          client: widget.client,
          speechInput: widget.speechInput,
          paneId: agent.paneId,
          initialAgent: agent,
          initialWorkspaceLabel: _workspaceLabels[agent.workspaceId],
          nativeTranscriptHistory: _nativeHistoryFor(agent.paneId),
        ),
      ),
    );
    if (!mounted) return;
    _startPolling();
    _load();
  }

  Future<bool> _confirmAndStop(AgentInfo agent) async {
    final name = _agentDisplayName(agent);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return AlertDialog(
          title: Text(l10n.herdStopDialogTitle),
          content: Text(l10n.herdStopDialogBody(name, agent.paneId)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.commonStop),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return false;

    setState(() => _stoppingPaneIds.add(agent.paneId));
    try {
      await widget.client.closeAgent(agent.paneId);
      await _load();
    } catch (e) {
      if (mounted) {
        showTopToast(context, e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _stoppingPaneIds.remove(agent.paneId));
      }
    }
    return false;
  }

  Future<String?> _promptRename({
    required String title,
    required String fieldLabel,
    required String initialValue,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final next = await showDialog<String>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            contextMenuBuilder: noScanTextContextMenuBuilder,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: fieldLabel,
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(MaterialLocalizations.of(context).saveButtonLabel),
            ),
          ],
        );
      },
    );
    return next?.trim();
  }

  Future<void> _renameWorkspace(String workspaceId) async {
    final l10n = AppLocalizations.of(context)!;
    final current = _workspaceLabel(workspaceId);
    final next = await _promptRename(
      title: l10n.herdRenameWorkspaceTitle,
      fieldLabel: l10n.herdRenameWorkspaceField,
      initialValue: current,
    );
    if (next == null || next.isEmpty || next == current || !mounted) return;
    try {
      await widget.client.renameWorkspace(workspaceId, next);
      if (!mounted) return;
      setState(() => _workspaceLabels[workspaceId] = next);
      _loadWorkspaceLabels();
    } catch (e) {
      if (mounted) showTopToast(context, e.toString());
    }
  }

  Future<void> _renameAgent(AgentInfo agent) async {
    final l10n = AppLocalizations.of(context)!;
    final current = agent.name ?? '';
    final next = await _promptRename(
      title: l10n.herdRenameAgentTitle,
      fieldLabel: l10n.herdRenameAgentField,
      initialValue: current,
    );
    if (next == null || next.isEmpty || next == current || !mounted) return;
    try {
      await widget.client.renameAgent(agent.paneId, next);
      await _load();
    } catch (e) {
      if (mounted) showTopToast(context, e.toString());
    }
  }

  Map<String, List<AgentInfo>> _grouped() {
    final groups = <String, List<AgentInfo>>{};
    for (final agent in _agents) {
      groups.putIfAbsent(agent.workspaceId, () => []).add(agent);
    }
    for (final list in groups.values) {
      list.sort((a, b) {
        final byStatus = _statusOrder[a.status]!.compareTo(
          _statusOrder[b.status]!,
        );
        if (byStatus != 0) return byStatus;
        return a.paneId.compareTo(b.paneId);
      });
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = _grouped();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Herd'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
              ],
            ),
          if (_workspaceLabelsError != null)
            MaterialBanner(
              content: Text(_workspaceLabelsError!),
              actions: [
                TextButton(
                  onPressed: _retryWorkspaceLabels,
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          Expanded(
            child: groups.isEmpty
                ? Center(child: Text(l10n.herdNoAgents))
                : ListView(
                    children: [
                      for (final entry in groups.entries) ...[
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: () => _renameWorkspace(entry.key),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                            child: Text(
                              _workspaceLabel(entry.key),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ),
                        for (final agent in entry.value)
                          Dismissible(
                            key: ValueKey('agent-${agent.paneId}'),
                            direction: _stoppingPaneIds.contains(agent.paneId)
                                ? DismissDirection.none
                                : DismissDirection.endToStart,
                            background: ColoredBox(
                              color: Theme.of(context).colorScheme.error,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.stop,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onError,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        l10n.commonStop,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onError,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            confirmDismiss: (_) => _confirmAndStop(agent),
                            child: _AgentTile(
                              agent: agent,
                              displayName: _agentDisplayName(agent),
                              metadata: _agentMetadata(agent),
                              onLongPress:
                                  _stoppingPaneIds.contains(agent.paneId)
                                  ? null
                                  : () => _renameAgent(agent),
                              onTap: _stoppingPaneIds.contains(agent.paneId)
                                  ? null
                                  : () => _openAgentScreen(agent),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('launch_agent_fab'),
        tooltip: l10n.commonLaunchAgent,
        onPressed: _openLaunchSheet,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.agent,
    required this.displayName,
    required this.metadata,
    required this.onTap,
    required this.onLongPress,
  });

  final AgentInfo agent;
  final String displayName;
  final String metadata;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      leading: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.circle, color: statusColor(agent.status), size: 14),
          Text(
            agentStatusLabel(l10n, agent.status),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      title: Text(displayName),
      subtitle: Text(
        metadata,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
