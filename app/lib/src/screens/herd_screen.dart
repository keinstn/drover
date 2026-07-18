import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../herdr/herdr_client.dart';
import '../models/agent_info.dart';
import '../utils/path.dart';
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
    this.pollInterval = const Duration(seconds: 2),
  });

  final HerdrClient client;
  final VoidCallback onOpenSettings;
  final Duration pollInterval;

  @override
  State<HerdScreen> createState() => _HerdScreenState();
}

class _HerdScreenState extends State<HerdScreen> {
  List<AgentInfo> _agents = [];
  String? _error;
  bool _loading = false;
  Timer? _timer;
  final _previousStatus = <String, AgentStatus>{};

  @override
  void initState() {
    super.initState();
    _load();
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _loading = false;
    }
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${agent.name ?? agent.agent} is blocked')),
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
          Expanded(
            child: groups.isEmpty
                ? const Center(child: Text('No agents found'))
                : ListView(
                    children: [
                      for (final entry in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            entry.key,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        for (final agent in entry.value)
                          _AgentTile(
                            agent: agent,
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => AgentScreen(
                                    client: widget.client,
                                    paneId: agent.paneId,
                                    initialAgent: agent,
                                  ),
                                ),
                              );
                            },
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
  final VoidCallback onTap;

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
      title: Text('${agent.name ?? agent.agent} · ${agent.paneId}'),
      subtitle: Text(lastPathSegment(cwd)),
      onTap: onTap,
    );
  }
}
