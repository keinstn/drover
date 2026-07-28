import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../agents/agent_native_history.dart';
import '../app_theme.dart';
import '../herdr/herdr_client.dart';
import '../herdr/herdr_version.dart';
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

/// The backoff delay before re-polling a host after [failStreak] consecutive
/// load failures: `pollInterval * 2^min(failStreak, 5)`, capped at 30
/// seconds. Pure so the schedule can be unit-tested without wall-clock
/// polling (widget tests run on fake timers but `DateTime.now()` is real).
Duration herdPollBackoff(int failStreak, Duration pollInterval) {
  const cap = Duration(seconds: 30);
  final delay = pollInterval * (1 << (failStreak < 5 ? failStreak : 5));
  return delay > cap ? cap : delay;
}

/// One stored host as the herd screen sees it: enough identity to key its
/// state bucket, plus [revision], which main.dart bumps whenever the host's
/// connection is rebuilt (config edit) so per-pane state bound to the old
/// runner can be discarded.
class HerdHostRef {
  const HerdHostRef({
    required this.hostId,
    required this.displayName,
    required this.revision,
    this.hostEverConnected = false,
  });

  final String hostId;
  final String displayName;
  final int revision;

  /// Whether this host has ever connected successfully (its host-key
  /// fingerprint is pinned) — used to pick a more specific "lost the
  /// connection" message over the generic "check the address" one when a
  /// [_HostHerd.error] surfaces. Defaults to false so callers that don't
  /// track this simply keep today's generic message.
  final bool hostEverConnected;

  @override
  bool operator ==(Object other) =>
      other is HerdHostRef &&
      other.hostId == hostId &&
      other.displayName == displayName &&
      other.revision == revision &&
      other.hostEverConnected == hostEverConnected;

  @override
  int get hashCode =>
      Object.hash(hostId, displayName, revision, hostEverConnected);
}

/// Per-host slice of the herd state. Everything the pre-multi-host screen
/// kept in flat paneId/workspaceId-keyed fields lives in one bucket per host
/// instead — pane and workspace ids are only unique within a host, and a
/// failing or slow host must never disturb another host's data.
class _HostHerd {
  List<AgentInfo> agents = [];
  Object? error;
  bool loading = false;

  /// Consecutive failed loads; drives [herdPollBackoff].
  int failStreak = 0;

  /// When set, the periodic poll skips this host until the backoff expires.
  DateTime? nextPollAt;

  Map<String, String> workspaceLabels = {};
  bool workspaceLabelsLoading = false;
  bool workspaceLabelsFailed = false;
  Object? workspaceLabelsError;

  /// This host's parsed herdr version, fetched once (like [workspaceLabels]).
  /// Stays null if the probe fails or its output is unparseable — a version
  /// warning simply isn't shown rather than blocking on an unrelated hiccup;
  /// [_HerdScreenState._herdrTooOldToLaunch] re-checks authoritatively before
  /// actually gating a launch.
  HerdrVersion? herdrVersion;
  bool herdrVersionLoading = false;

  final previousStatus = <String, AgentStatus>{};

  // When each pane was first seen in its current status, so a tile can show a
  // client-side "N分前" since its last status change. Recorded/updated in
  // [_HerdScreenState._checkBlockedTransitions]; pruned with the same
  // lifecycle as [nativeHistory] in [_HerdScreenState._loadHost].
  final statusChangedAt = <String, DateTime>{};

  final stoppingPaneIds = <String>{};

  // One `NativeTranscriptHistory` per pane, owned by this screen (not
  // global/static state) and injected into `AgentScreen` on open so
  // reopening the same pane resumes from its already-loaded window/offset
  // state instead of re-fetching from scratch. Each instance still
  // re-resolves/resets itself when that pane's agent session identity
  // changes (see `NativeTranscriptHistory`); entries for panes no longer
  // reported by the herd are dropped in [_HerdScreenState._loadHost].
  final nativeHistory = <String, NativeTranscriptHistory>{};
}

/// The main screen: a live list of every agent every stored Herdr host knows
/// about, grouped by host and workspace and polled every [pollInterval].
class HerdScreen extends StatefulWidget {
  const HerdScreen({
    super.key,
    required this.hosts,
    required this.clientFor,
    this.filterHostId,
    required this.onOpenHostSwitcher,
    required this.onOpenSettings,
    this.speechInput,
    this.pollInterval = const Duration(seconds: 2),
  });

  /// Every stored host, in display order.
  final List<HerdHostRef> hosts;

  /// Lazily resolves the live client for a host. Backed by main.dart's
  /// connection registry, so repeated calls are cheap and return the same
  /// client until the host's [HerdHostRef.revision] is bumped.
  final HerdrClient Function(HerdHostRef) clientFor;

  /// When set, only the matching host is polled and rendered; null means
  /// "All hosts".
  final String? filterHostId;

  /// Opens the host switcher (the app-bar chip tap); main owns the sheet.
  final VoidCallback onOpenHostSwitcher;

  final VoidCallback onOpenSettings;
  final SpeechInput? speechInput;
  final Duration pollInterval;

  @override
  State<HerdScreen> createState() => _HerdScreenState();
}

class _HerdScreenState extends State<HerdScreen> {
  final _byHost = <String, _HostHerd>{};
  Timer? _timer;

  /// The hosts the screen currently polls and renders: all of them, or just
  /// the [HerdScreen.filterHostId] match.
  List<HerdHostRef> get _hostsInScope =>
      _scopeOf(widget.hosts, widget.filterHostId);

  static List<HerdHostRef> _scopeOf(List<HerdHostRef> hosts, String? filter) =>
      filter == null
      ? hosts
      : [
          for (final host in hosts)
            if (host.hostId == filter) host,
        ];

  _HostHerd _bucketFor(String hostId) =>
      _byHost.putIfAbsent(hostId, () => _HostHerd());

  @override
  void initState() {
    super.initState();
    for (final host in _hostsInScope) {
      unawaited(_loadHost(host));
      unawaited(_loadWorkspaceLabels(host));
      unawaited(_loadHerdrVersion(host));
    }
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant HerdScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = {for (final host in widget.hosts) host.hostId};
    _byHost.removeWhere((hostId, _) => !ids.contains(hostId));
    for (final host in widget.hosts) {
      for (final old in oldWidget.hosts) {
        if (old.hostId == host.hostId && old.revision != host.revision) {
          // The host's connection was rebuilt: cached NativeTranscriptHistory
          // instances are bound to the dead runner, so start the bucket over.
          _byHost.remove(host.hostId);
        }
      }
    }
    // Hosts that just came into scope (filter change, added host, reset
    // bucket) load immediately instead of waiting for the next poll tick.
    final oldScope = {
      for (final host in _scopeOf(oldWidget.hosts, oldWidget.filterHostId))
        host.hostId,
    };
    for (final host in _hostsInScope) {
      if (!oldScope.contains(host.hostId) ||
          !_byHost.containsKey(host.hostId)) {
        unawaited(_loadHost(host));
        unawaited(_loadWorkspaceLabels(host));
        unawaited(_loadHerdrVersion(host));
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Starts (or restarts) the periodic poll. A no-op if already running:
  /// [_loadHost] itself is guarded per bucket, so calling this twice in a row
  /// would otherwise leak the original [Timer].
  void _startPolling() {
    _timer ??= Timer.periodic(widget.pollInterval, (_) => _pollTick());
  }

  /// Stops the periodic poll without touching in-flight [_loadHost] calls,
  /// which remain safe to finish on their own (each checks [mounted] and
  /// guards re-entrancy via its bucket's `loading`).
  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// One poll tick: refresh every in-scope host, skipping ones with a load
  /// already in flight or still inside their failure backoff window.
  void _pollTick() {
    final now = DateTime.now();
    for (final host in _hostsInScope) {
      final bucket = _bucketFor(host.hostId);
      if (bucket.loading) continue;
      final nextPollAt = bucket.nextPollAt;
      if (nextPollAt != null && now.isBefore(nextPollAt)) continue;
      unawaited(_loadHost(host));
    }
  }

  /// The cached native-history/loader instance for [paneId] on [host],
  /// creating one on first use.
  NativeTranscriptHistory _nativeHistoryFor(HerdHostRef host, String paneId) {
    final client = widget.clientFor(host);
    return _bucketFor(host.hostId).nativeHistory.putIfAbsent(
      paneId,
      () =>
          NativeTranscriptHistory(client.runner, platform: client.hostPlatform),
    );
  }

  Future<void> _loadHost(HerdHostRef host) async {
    final bucket = _bucketFor(host.hostId);
    if (bucket.loading) return;
    bucket.loading = true;
    try {
      final agents = await widget.clientFor(host).listAgents();
      if (!mounted || !identical(_byHost[host.hostId], bucket)) return;
      _checkBlockedTransitions(bucket, agents);
      setState(() {
        bucket.agents = agents;
        bucket.error = null;
        bucket.failStreak = 0;
        bucket.nextPollAt = null;
      });
      // Drop any cached history for a pane the herd no longer reports (the
      // agent stopped/exited), so the cache doesn't grow unboundedly.
      final panes = agents.map((agent) => agent.paneId).toSet();
      bucket.nativeHistory.removeWhere((paneId, _) => !panes.contains(paneId));
      bucket.statusChangedAt.removeWhere(
        (paneId, _) => !panes.contains(paneId),
      );
      // Also drop the dead pane's last-seen status, so a reused paneId
      // doesn't inherit it.
      bucket.previousStatus.removeWhere((paneId, _) => !panes.contains(paneId));
      if (!bucket.workspaceLabelsFailed &&
          agents.any(
            (agent) => !bucket.workspaceLabels.containsKey(agent.workspaceId),
          )) {
        unawaited(_loadWorkspaceLabels(host));
      }
    } catch (e) {
      if (!mounted || !identical(_byHost[host.hostId], bucket)) return;
      setState(() {
        bucket.error = e;
        bucket.failStreak++;
        bucket.nextPollAt = DateTime.now().add(
          herdPollBackoff(bucket.failStreak, widget.pollInterval),
        );
      });
    } finally {
      bucket.loading = false;
    }
  }

  Future<void> _loadWorkspaceLabels(HerdHostRef host) async {
    final bucket = _bucketFor(host.hostId);
    if (bucket.workspaceLabelsLoading) return;
    bucket.workspaceLabelsLoading = true;
    try {
      final workspaces = await widget.clientFor(host).listWorkspaces();
      if (!mounted || !identical(_byHost[host.hostId], bucket)) return;
      setState(() {
        bucket.workspaceLabelsFailed = false;
        bucket.workspaceLabelsError = null;
        bucket.workspaceLabels = {
          for (final workspace in workspaces)
            workspace.workspaceId: workspace.label.isEmpty
                ? workspace.workspaceId
                : workspace.label,
        };
      });
    } catch (e) {
      if (!mounted || !identical(_byHost[host.hostId], bucket)) return;
      setState(() {
        bucket.workspaceLabelsFailed = true;
        bucket.workspaceLabelsError = e;
      });
    } finally {
      bucket.workspaceLabelsLoading = false;
    }
  }

  /// Fetches and caches [host]'s herdr version once, so a persistent warning
  /// can be shown without re-probing on every poll tick. Any transport
  /// failure or unparseable `--version` output is swallowed — this cache is
  /// best-effort; [_herdrTooOldToLaunch] is the authoritative check.
  Future<void> _loadHerdrVersion(HerdHostRef host) async {
    final bucket = _bucketFor(host.hostId);
    if (bucket.herdrVersionLoading || bucket.herdrVersion != null) return;
    bucket.herdrVersionLoading = true;
    try {
      final version = parseHerdrVersion(await widget.clientFor(host).version());
      if (version == null ||
          !mounted ||
          !identical(_byHost[host.hostId], bucket)) {
        return;
      }
      setState(() => bucket.herdrVersion = version);
    } catch (_) {
      // Fail open: an unreachable/erroring probe never shows a warning.
    } finally {
      bucket.herdrVersionLoading = false;
    }
  }

  /// Clears [host]'s error state (including the poll backoff) and reloads it
  /// right away.
  void _retryHost(HerdHostRef host) {
    final bucket = _bucketFor(host.hostId);
    setState(() {
      bucket.error = null;
      bucket.failStreak = 0;
      bucket.nextPollAt = null;
    });
    unawaited(_loadHost(host));
  }

  void _retryWorkspaceLabels(HerdHostRef host) {
    final bucket = _bucketFor(host.hostId);
    setState(() {
      bucket.workspaceLabelsFailed = false;
      bucket.workspaceLabelsError = null;
    });
    unawaited(_loadWorkspaceLabels(host));
  }

  String _workspaceLabel(_HostHerd bucket, String workspaceId) =>
      bucket.workspaceLabels[workspaceId] ?? workspaceId;

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
  String _snippetFor(_HostHerd bucket, AgentInfo agent, AppLocalizations l10n) {
    final cached = bucket.nativeHistory[agent.paneId]?.latest;
    return activitySnippet(cached, l10n) ?? _agentMetadata(agent);
  }

  void _checkBlockedTransitions(_HostHerd bucket, List<AgentInfo> agents) {
    final now = DateTime.now();
    for (final agent in agents) {
      final previous = bucket.previousStatus[agent.paneId];
      final seenBefore = bucket.previousStatus.containsKey(agent.paneId);
      if (!seenBefore || previous != agent.status) {
        bucket.statusChangedAt[agent.paneId] = now;
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
      bucket.previousStatus[agent.paneId] = agent.status;
    }
  }

  List<String> _distinctCwds(_HostHerd bucket) {
    final seen = <String>{};
    final cwds = <String>[];
    for (final agent in bucket.agents) {
      final cwd = agent.foregroundCwd ?? agent.cwd;
      if (seen.add(cwd)) cwds.add(cwd);
    }
    return cwds;
  }

  /// FAB tap: launch on the filtered (or only) host directly; in the
  /// All-hosts view with several hosts, ask which host to launch on first.
  Future<void> _onLaunchPressed() async {
    HerdHostRef? target;
    if (widget.filterHostId != null || widget.hosts.length == 1) {
      final scope = _hostsInScope;
      target = scope.isEmpty ? null : scope.first;
    } else {
      target = await _pickLaunchHost();
    }
    if (target == null || !mounted) return;
    if (await _herdrTooOldToLaunch(target)) return;
    if (!mounted) return;
    await _openLaunchSheet(target);
  }

  /// Authoritatively re-checks [host]'s herdr version right before opening
  /// the launch sheet — [_HostHerd.herdrVersion] may not have arrived yet,
  /// so trusting only the cached value would let a fast launch tap race past
  /// it. Any transport failure or unparseable output fails open (returns
  /// false): a hiccup here must never newly block an otherwise-working
  /// launch. Returns true (and shows a toast) when the launch should be
  /// blocked.
  Future<bool> _herdrTooOldToLaunch(HerdHostRef host) async {
    final bucket = _bucketFor(host.hostId);
    var version = bucket.herdrVersion;
    if (version == null) {
      try {
        version = parseHerdrVersion(await widget.clientFor(host).version());
      } catch (_) {
        return false;
      }
      if (version == null) return false;
      if (mounted && identical(_byHost[host.hostId], bucket)) {
        setState(() => bucket.herdrVersion = version);
      }
    }
    if (isHerdrVersionSupported(version)) return false;
    if (!mounted) return true;
    showTopToast(
      context,
      errorHeadline(
        AppLocalizations.of(context)!,
        HerdrVersionUnsupportedException(
          found: formatHerdrVersion(version),
          minimum: formatHerdrVersion(kMinHerdrVersion),
        ),
      ),
    );
    return true;
  }

  Future<HerdHostRef?> _pickLaunchHost() {
    return showModalBottomSheet<HerdHostRef>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  l10n.hostPickLaunchTarget,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final host in widget.hosts)
                ListTile(
                  key: ValueKey('launch_host_${host.hostId}'),
                  title: Text(
                    host.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, host),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openLaunchSheet(HerdHostRef host) async {
    final launched = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: LaunchAgentSheet(
          client: widget.clientFor(host),
          existingCwds: _distinctCwds(_bucketFor(host.hostId)),
        ),
      ),
    );
    if (launched == true) unawaited(_loadHost(host));
  }

  /// Pushes the detail screen for [agent], suspending the periodic
  /// `listAgents` poll for the duration of that route. `HerdScreen`
  /// stays mounted (and visible) behind the pushed route, so without this its
  /// 2-second poll would keep contending for the single mutex-serialized SSH
  /// channel that `AgentScreen` needs for its own (now progressive) loading.
  /// Polling resumes, and an immediate refresh is kicked off, once the route
  /// is popped — or once the switcher bar replaces it (`pushReplacement`
  /// completes this await early). The resumed poll then runs alongside the
  /// replacement screen's own `listAgents` poll; both go through the same
  /// serialized SSH channel, and it keeps blocked-transition toasts alive
  /// while the user hops between agents.
  Future<void> _openAgentScreen(HerdHostRef host, AgentInfo agent) async {
    final bucket = _bucketFor(host.hostId);
    _stopPolling();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentScreen(
          client: widget.clientFor(host),
          speechInput: widget.speechInput,
          paneId: agent.paneId,
          initialAgent: agent,
          initialAgents: bucket.agents,
          initialWorkspaceLabel: bucket.workspaceLabels[agent.workspaceId],
          draftKeyPrefix: host.hostId,
          nativeTranscriptHistory: _nativeHistoryFor(host, agent.paneId),
          nativeHistoryResolver: (paneId) => _nativeHistoryFor(host, paneId),
        ),
      ),
    );
    if (!mounted) return;
    _startPolling();
    for (final inScope in _hostsInScope) {
      unawaited(_loadHost(inScope));
    }
  }

  Future<bool> _confirmAndStop(HerdHostRef host, AgentInfo agent) async {
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

    final bucket = _bucketFor(host.hostId);
    setState(() => bucket.stoppingPaneIds.add(agent.paneId));
    try {
      await widget.clientFor(host).closeAgent(agent.paneId);
      await _loadHost(host);
    } catch (e) {
      if (mounted) {
        showTopToast(context, errorHeadline(AppLocalizations.of(context)!, e));
      }
    } finally {
      if (mounted) {
        setState(() => bucket.stoppingPaneIds.remove(agent.paneId));
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

  Future<void> _renameWorkspace(HerdHostRef host, String workspaceId) async {
    final l10n = AppLocalizations.of(context)!;
    final bucket = _bucketFor(host.hostId);
    final current = _workspaceLabel(bucket, workspaceId);
    final next = await _promptRename(
      title: l10n.herdRenameWorkspaceTitle,
      fieldLabel: l10n.herdRenameWorkspaceField,
      initialValue: current,
    );
    if (next == null || next.isEmpty || next == current || !mounted) return;
    try {
      await widget.clientFor(host).renameWorkspace(workspaceId, next);
      if (!mounted) return;
      setState(() => bucket.workspaceLabels[workspaceId] = next);
      unawaited(_loadWorkspaceLabels(host));
    } catch (e) {
      if (mounted) showTopToast(context, errorHeadline(l10n, e));
    }
  }

  Future<void> _renameAgent(HerdHostRef host, AgentInfo agent) async {
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
      await widget.clientFor(host).renameAgent(agent.paneId, next);
      await _loadHost(host);
    } catch (e) {
      if (mounted) showTopToast(context, errorHeadline(l10n, e));
    }
  }

  Map<String, List<AgentInfo>> _grouped(_HostHerd bucket) {
    final groups = <String, List<AgentInfo>>{};
    for (final agent in bucket.agents) {
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

  /// Per-status agent counts across every in-scope host, used by both the
  /// greeting (blocked) and the status-chip row.
  Map<AgentStatus, int> _statusCounts() {
    final counts = <AgentStatus, int>{};
    for (final host in _hostsInScope) {
      final bucket = _byHost[host.hostId];
      if (bucket == null) continue;
      for (final agent in bucket.agents) {
        counts[agent.status] = (counts[agent.status] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// True when no in-scope host has agents or an error to show — the herd is
  /// genuinely empty rather than partially broken.
  bool get _isEmpty => _hostsInScope.every((host) {
    final bucket = _byHost[host.hostId];
    return bucket == null || (bucket.agents.isEmpty && bucket.error == null);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final counts = _statusCounts();
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        // The host chip adds a second line under the title; the default 56px
        // toolbar would overflow it.
        toolbarHeight: 64,
        title: _appBarTitle(l10n),
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
          _greeting(l10n, counts[AgentStatus.blocked] ?? 0),
          _statusChips(l10n, counts),
          Expanded(
            child: _isEmpty
                ? Center(child: Text(l10n.herdNoAgents))
                : ListView(
                    children: [
                      for (final host in _hostsInScope)
                        ..._hostSection(context, l10n, host, now),
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
          onPressed: _onLaunchPressed,
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          icon: const Icon(Icons.add),
          label: Text(l10n.commonLaunchAgent),
        ),
      ),
    );
  }

  /// The plain bold 'Drover' title plus a smaller tappable "▾ host" chip
  /// beneath it that opens the host switcher: the filtered host's name, or
  /// "All hosts" when no filter is set.
  Widget _appBarTitle(AppLocalizations l10n) {
    const title = Text(
      'Drover',
      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
    );
    var label = l10n.hostAllHosts;
    for (final host in widget.hosts) {
      if (host.hostId == widget.filterHostId) label = host.displayName;
    }
    final subdued = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        InkWell(
          key: const ValueKey('host_switcher_chip'),
          onTap: widget.onOpenHostSwitcher,
          borderRadius: BorderRadius.circular(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_drop_down, size: 16, color: subdued),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: subdued,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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

  /// One host's slice of the list: an optional section header (only when
  /// several hosts are stored — single-host users keep the old look), any
  /// per-host error rows, then its workspace cards. Errors stay inside the
  /// section so one unreachable host never hides the others.
  List<Widget> _hostSection(
    BuildContext context,
    AppLocalizations l10n,
    HerdHostRef host,
    DateTime now,
  ) {
    final bucket = _bucketFor(host.hostId);
    final error = bucket.error;
    final workspaceLabelsError = bucket.workspaceLabelsError;
    final herdrVersion = bucket.herdrVersion;
    final herdrVersionTooOld =
        herdrVersion != null && !isHerdrVersionSupported(herdrVersion);
    return [
      if (widget.hosts.length > 1) _hostHeader(host),
      if (error != null)
        _errorRow(
          l10n,
          error,
          retryKey: ValueKey('host_retry_${host.hostId}'),
          onRetry: () => _retryHost(host),
          hostEverConnected: host.hostEverConnected,
        ),
      if (workspaceLabelsError != null)
        _errorRow(
          l10n,
          workspaceLabelsError,
          onRetry: () => _retryWorkspaceLabels(host),
          hostEverConnected: host.hostEverConnected,
        ),
      // No retry button: unlike a transient load failure, a stale herdr
      // binary on the host isn't fixed by retrying from drover.
      if (herdrVersionTooOld)
        Padding(
          key: ValueKey('herdr_version_warning_${host.hostId}'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: ErrorMessageView(
            HerdrVersionUnsupportedException(
              found: formatHerdrVersion(herdrVersion),
              minimum: formatHerdrVersion(kMinHerdrVersion),
            ),
          ),
        ),
      for (final entry in _grouped(bucket).entries)
        _workspaceCard(context, l10n, host, bucket, entry, now),
    ];
  }

  /// A subdued host name above the host's workspace cards, visually distinct
  /// from the uppercase-styled workspace headers inside the cards.
  Widget _hostHeader(HerdHostRef host) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
      child: Row(
        children: [
          Icon(
            Icons.dns_outlined,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              host.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A compact in-section error: the localized message plus a Retry button.
  Widget _errorRow(
    AppLocalizations l10n,
    Object error, {
    Key? retryKey,
    required VoidCallback onRetry,
    bool hostEverConnected = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ErrorMessageView(
              error,
              hostEverConnected: hostEverConnected,
            ),
          ),
          TextButton(
            key: retryKey,
            onPressed: onRetry,
            child: Text(l10n.commonRetry),
          ),
        ],
      ),
    );
  }

  Widget _workspaceCard(
    BuildContext context,
    AppLocalizations l10n,
    HerdHostRef host,
    _HostHerd bucket,
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
                // Cool to match the light theme's axis; this was a warm brown
                // left over from the original warm palette.
                BoxShadow(
                  color: Color.fromRGBO(60, 60, 75, 0.07),
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
            onLongPress: () => _renameWorkspace(host, entry.key),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
              child: Text(
                _workspaceLabel(bucket, entry.key),
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
              // Pane ids are only unique within a host, so the host id keeps
              // same-numbered panes on different hosts from colliding.
              key: ValueKey('agent-${host.hostId}-${agent.paneId}'),
              direction: bucket.stoppingPaneIds.contains(agent.paneId)
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
              confirmDismiss: (_) => _confirmAndStop(host, agent),
              child: _AgentTile(
                agent: agent,
                displayName: _agentDisplayName(agent),
                snippet: _snippetFor(bucket, agent, l10n),
                elapsed: formatElapsed(
                  now.difference(bucket.statusChangedAt[agent.paneId] ?? now),
                  l10n,
                ),
                onLongPress: bucket.stoppingPaneIds.contains(agent.paneId)
                    ? null
                    : () => _renameAgent(host, agent),
                onTap: bucket.stoppingPaneIds.contains(agent.paneId)
                    ? null
                    : () => _openAgentScreen(host, agent),
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
