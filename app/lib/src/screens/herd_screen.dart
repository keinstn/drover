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
import '../transcript/activity_snippet.dart';
import '../utils/path.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/error_message_view.dart';
import '../widgets/status_pill.dart';
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

/// A short, human "how long ago" label for [elapsed] since an agent last
/// changed status: "now" under a minute, "N分前"/"Nm ago" under an hour,
/// else "N時間前"/"Nh ago". Pure so it can be unit-tested at boundaries.
String formatElapsed(Duration elapsed, AppLocalizations l10n) {
  if (elapsed.inSeconds < 60) return l10n.herdElapsedNow;
  if (elapsed.inMinutes < 60) return l10n.herdElapsedMinutes(elapsed.inMinutes);
  return l10n.herdElapsedHours(elapsed.inHours);
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
  Object? _error;
  Object? _workspaceLabelsError;
  bool _loading = false;
  bool _workspaceLabelsLoading = false;
  bool _workspaceLabelsFailed = false;
  Timer? _timer;
  final _previousStatus = <String, AgentStatus>{};
  // When each pane was first seen in its current status, so a tile can show a
  // client-side "N分前" since its last status change. Recorded/updated in
  // [_checkBlockedTransitions]; pruned with the same lifecycle as
  // [_nativeHistoryCache] in [_load].
  final _statusChangedAt = <String, DateTime>{};
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
        () => NativeTranscriptHistory(
          widget.client.runner,
          platform: widget.client.hostPlatform,
        ),
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
      _statusChangedAt.removeWhere((paneId, _) => !panes.contains(paneId));
      if (!_workspaceLabelsFailed &&
          agents.any(
            (agent) => !_workspaceLabels.containsKey(agent.workspaceId),
          )) {
        _loadWorkspaceLabels();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
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
        _workspaceLabelsError = e;
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

  /// A best-effort "what is it doing" line for [agent]'s tile: derived from
  /// the latest cached native transcript for its pane when one has been
  /// loaded (i.e. the pane's `AgentScreen` was opened at least once this
  /// session), else the `agentType · cwd` metadata fallback. Never loads
  /// native history itself — the poll must not contend for the serialized
  /// SSH channel (see [_openAgentScreen]).
  String _snippetFor(AgentInfo agent, AppLocalizations l10n) {
    final cached = _nativeHistoryCache[agent.paneId]?.latest;
    return activitySnippet(cached, l10n) ?? _agentMetadata(agent);
  }

  void _checkBlockedTransitions(List<AgentInfo> agents) {
    final now = DateTime.now();
    for (final agent in agents) {
      final previous = _previousStatus[agent.paneId];
      final seenBefore = _previousStatus.containsKey(agent.paneId);
      if (!seenBefore || previous != agent.status) {
        _statusChangedAt[agent.paneId] = now;
      }
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
  /// is popped — or once the switcher bar replaces it (`pushReplacement`
  /// completes this await early). The resumed poll then runs alongside the
  /// replacement screen's own `listAgents` poll; both go through the same
  /// serialized SSH channel, and it keeps blocked-transition toasts alive
  /// while the user hops between agents.
  Future<void> _openAgentScreen(AgentInfo agent) async {
    _stopPolling();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentScreen(
          client: widget.client,
          speechInput: widget.speechInput,
          paneId: agent.paneId,
          initialAgent: agent,
          initialAgents: _agents,
          initialWorkspaceLabel: _workspaceLabels[agent.workspaceId],
          nativeTranscriptHistory: _nativeHistoryFor(agent.paneId),
          nativeHistoryResolver: _nativeHistoryFor,
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
        showTopToast(context, errorHeadline(AppLocalizations.of(context)!, e));
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
    String? hintText,
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
              hintText: hintText,
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
      if (mounted) showTopToast(context, errorHeadline(l10n, e));
    }
  }

  Future<void> _renameAgent(AgentInfo agent) async {
    final l10n = AppLocalizations.of(context)!;
    final current = agent.name ?? '';
    final next = await _promptRename(
      title: l10n.herdRenameAgentTitle,
      fieldLabel: l10n.herdRenameAgentField,
      initialValue: current,
      hintText: agent.agent,
    );
    if (next == null || next.isEmpty || next == current || !mounted) return;
    try {
      await widget.client.renameAgent(agent.paneId, next);
      await _load();
    } catch (e) {
      if (mounted) showTopToast(context, errorHeadline(l10n, e));
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

  /// Per-status agent counts, used by both the greeting (blocked) and the
  /// status-chip row.
  Map<AgentStatus, int> _statusCounts() {
    final counts = <AgentStatus, int>{};
    for (final agent in _agents) {
      counts[agent.status] = (counts[agent.status] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = _grouped();
    final counts = _statusCounts();
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text(
          'Drover',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            MaterialBanner(
              content: ErrorMessageView(_error!),
              actions: [
                TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
              ],
            ),
          if (_workspaceLabelsError != null)
            MaterialBanner(
              content: ErrorMessageView(_workspaceLabelsError!),
              actions: [
                TextButton(
                  onPressed: _retryWorkspaceLabels,
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          _greeting(l10n, counts[AgentStatus.blocked] ?? 0),
          _statusChips(l10n, counts),
          Expanded(
            child: groups.isEmpty
                ? Center(child: Text(l10n.herdNoAgents))
                : ListView(
                    children: [
                      for (final entry in groups.entries)
                        _workspaceCard(context, l10n, entry, now),
                    ],
                  ),
          ),
        ],
      ),
      // The spec's pill FAB is 48px tall; the tight SizedBox overrides the
      // M3 extended-FAB default (56px).
      floatingActionButton: SizedBox(
        height: 48,
        child: FloatingActionButton.extended(
          key: const ValueKey('launch_agent_fab'),
          tooltip: l10n.commonLaunchAgent,
          onPressed: _openLaunchSheet,
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          icon: const Icon(Icons.add),
          label: Text(l10n.commonLaunchAgent),
        ),
      ),
    );
  }

  Widget _greeting(AppLocalizations l10n, int blockedCount) {
    final colors = DroverColors.of(context);
    final baseStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w500,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
      child: Text.rich(
        TextSpan(
          children: blockedCount > 0
              ? [
                  TextSpan(text: l10n.herdGreetingIntro),
                  TextSpan(
                    text: l10n.herdGreetingWaitingCount(blockedCount),
                    style: TextStyle(
                      color: colors.blockedPillFg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: l10n.herdGreetingWaitingSuffix),
                ]
              : [
                  TextSpan(text: l10n.herdGreetingIntro),
                  TextSpan(text: l10n.herdGreetingAllClear),
                ],
        ),
        style: baseStyle,
      ),
    );
  }

  Widget _statusChips(AppLocalizations l10n, Map<AgentStatus, int> counts) {
    final statuses = <AgentStatus>[
      AgentStatus.blocked,
      AgentStatus.working,
      AgentStatus.done,
      AgentStatus.idle,
      if ((counts[AgentStatus.unknown] ?? 0) > 0) AgentStatus.unknown,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final status in statuses)
            _StatusChip(status: status, count: counts[status] ?? 0),
        ],
      ),
    );
  }

  Widget _workspaceCard(
    BuildContext context,
    AppLocalizations l10n,
    MapEntry<String, List<AgentInfo>> entry,
    DateTime now,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: isLight ? Border.all(color: scheme.outline) : null,
        boxShadow: isLight
            ? const [
                BoxShadow(
                  color: Color.fromRGBO(120, 100, 70, 0.06),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => _renameWorkspace(entry.key),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
              child: Text(
                _workspaceLabel(entry.key),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                  color: DroverColors.of(context).tertiaryText,
                ),
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
                color: scheme.error,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.stop, color: scheme.onError),
                        const SizedBox(width: 8),
                        Text(
                          l10n.commonStop,
                          style: TextStyle(color: scheme.onError),
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
                snippet: _snippetFor(agent, l10n),
                elapsed: formatElapsed(
                  now.difference(_statusChangedAt[agent.paneId] ?? now),
                  l10n,
                ),
                onLongPress: _stoppingPaneIds.contains(agent.paneId)
                    ? null
                    : () => _renameAgent(agent),
                onTap: _stoppingPaneIds.contains(agent.paneId)
                    ? null
                    : () => _openAgentScreen(agent),
              ),
            ),
        ],
      ),
    );
  }
}

/// A pill in the herd summary row: a status color dot, its localized label,
/// and the current count for that status.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.count});

  final AgentStatus status;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.statusPillBg(status),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: colors.statusDot(status),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '${agentStatusLabel(l10n, status)} $count',
            style: TextStyle(
              color: colors.statusPillFg(status),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.agent,
    required this.displayName,
    required this.snippet,
    required this.elapsed,
    required this.onTap,
    required this.onLongPress,
  });

  final AgentInfo agent;
  final String displayName;
  final String snippet;
  final String elapsed;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            AgentAvatar(agent: agent.agent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    snippet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                StatusPill(status: agent.status),
                const SizedBox(height: 3),
                Text(
                  elapsed,
                  style: TextStyle(fontSize: 10, color: colors.tertiaryText),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
