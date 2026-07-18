import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../herdr/herdr_client.dart';
import '../models/agent_info.dart';
import '../speech/speech_input.dart';
import '../utils/path.dart';
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
      return Colors.red;
    case AgentStatus.working:
      return Colors.amber;
    case AgentStatus.idle:
      return Colors.green;
    case AgentStatus.done:
      return Colors.blue;
    case AgentStatus.unknown:
      return Colors.grey;
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

  @override
  void initState() {
    super.initState();
    _load();
    _loadWorkspaceLabels();
    _timer = Timer.periodic(widget.pollInterval, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

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

  void _checkBlockedTransitions(List<AgentInfo> agents) {
    for (final agent in agents) {
      final previous = _previousStatus[agent.paneId];
      final seenBefore = _previousStatus.containsKey(agent.paneId);
      if (seenBefore &&
          previous != AgentStatus.blocked &&
          agent.status == AgentStatus.blocked) {
        HapticFeedback.heavyImpact();
        if (mounted) {
          showTopToast(context, '${agent.name ?? agent.agent} is blocked');
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

  Future<bool> _confirmAndStop(AgentInfo agent) async {
    final name = agent.name ?? agent.agent;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop agent?'),
        content: Text(
          '$name (${agent.paneId}) will be stopped. '
          'Any current work will be interrupted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
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
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          if (_workspaceLabelsError != null)
            MaterialBanner(
              content: Text(_workspaceLabelsError!),
              actions: [
                TextButton(
                  onPressed: _retryWorkspaceLabels,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: groups.isEmpty
                ? const Center(child: Text('No agents found'))
                : ListView(
                    children: [
                      for (final entry in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            _workspaceLabel(entry.key),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        for (final agent in entry.value)
                          Dismissible(
                            key: ValueKey('agent-${agent.paneId}'),
                            direction: _stoppingPaneIds.contains(agent.paneId)
                                ? DismissDirection.none
                                : DismissDirection.endToStart,
                            background: const ColoredBox(
                              color: Colors.red,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: EdgeInsets.only(right: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.stop, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text(
                                        'Stop',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            confirmDismiss: (_) => _confirmAndStop(agent),
                            child: _AgentTile(
                              agent: agent,
                              onTap: _stoppingPaneIds.contains(agent.paneId)
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => AgentScreen(
                                            client: widget.client,
                                            speechInput: widget.speechInput,
                                            paneId: agent.paneId,
                                            initialAgent: agent,
                                            initialWorkspaceLabel:
                                                _workspaceLabels[agent
                                                    .workspaceId],
                                          ),
                                        ),
                                      );
                                    },
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
        tooltip: 'Launch agent',
        onPressed: _openLaunchSheet,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({required this.agent, required this.onTap});

  final AgentInfo agent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cwd = agent.foregroundCwd ?? agent.cwd;
    return ListTile(
      leading: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.circle, color: statusColor(agent.status), size: 14),
          Text(
            agent.status.name,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      title: Text(agent.name ?? agent.agent),
      subtitle: Text(lastPathSegment(cwd)),
      onTap: onTap,
    );
  }
}
