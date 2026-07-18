import 'dart:async';

import 'package:flutter/material.dart';

import '../herdr/herdr_client.dart';
import '../herdr/pane_text.dart';
import '../models/agent_info.dart';
import 'herd_screen.dart' show statusColor;

/// Detail screen for a single agent's pane: a live transcript, quick actions,
/// and a message composer.
class AgentScreen extends StatefulWidget {
  const AgentScreen({
    super.key,
    required this.client,
    required this.paneId,
    this.initialAgent,
    this.initialWorkspaceLabel,
    this.pollInterval = const Duration(seconds: 2),
  });

  final HerdrClient client;
  final String paneId;
  final AgentInfo? initialAgent;
  final String? initialWorkspaceLabel;
  final Duration pollInterval;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  AgentInfo? _agent;
  String _text = '';
  bool _loading = false;
  bool _firstLoad = true;
  bool _sending = false;
  bool _workspaceLabelLoading = false;
  String? _workspaceLabel;
  String? _workspaceLabelError;
  Timer? _timer;

  final _scrollController = ScrollController();
  final _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _agent = widget.initialAgent;
    _workspaceLabel = widget.initialWorkspaceLabel;
    _load();
    if (_agent != null && _workspaceLabel == null) _loadWorkspaceLabel();
    _timer = Timer.periodic(widget.pollInterval, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  bool get _wasAtBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 40;
  }

  Future<void> _loadWorkspaceLabel() async {
    if (_workspaceLabelLoading) return;
    final workspaceId = _agent?.workspaceId;
    if (workspaceId == null) return;
    _workspaceLabelLoading = true;
    try {
      final workspaces = await widget.client.listWorkspaces();
      if (!mounted) return;
      final workspace = workspaces
          .where((workspace) => workspace.workspaceId == workspaceId)
          .firstOrNull;
      setState(() {
        _workspaceLabel = workspace == null || workspace.label.isEmpty
            ? workspaceId
            : workspace.label;
        _workspaceLabelError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _workspaceLabelError = e.toString());
    } finally {
      _workspaceLabelLoading = false;
    }
  }

  void _retryWorkspaceLabel() {
    setState(() => _workspaceLabelError = null);
    _loadWorkspaceLabel();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final stickToBottom = _firstLoad || _wasAtBottom;
    try {
      final agent = await widget.client.getAgent(widget.paneId);
      final text = await widget.client.readAgent(widget.paneId, lines: 120);
      if (!mounted) return;
      setState(() {
        _agent = agent;
        _text = text;
        _firstLoad = false;
      });
      if (_workspaceLabel == null &&
          _workspaceLabelError == null &&
          !_workspaceLabelLoading) {
        _loadWorkspaceLabel();
      }
      if (stickToBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        });
      }
    } catch (_) {
      // Keep last known state on read/poll errors; the transcript stays
      // visible and the next tick will retry.
    } finally {
      _loading = false;
    }
  }

  Future<bool> _send(Future<void> Function() action) async {
    if (_sending) return false;
    setState(() => _sending = true);
    try {
      await action();
      await _load();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text;
    if (text.trim().isEmpty) return;
    final ok = await _send(() => widget.client.prompt(widget.paneId, text));
    if (ok) _messageController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    final displayName = agent?.name ?? agent?.agent ?? widget.paneId;
    final workspaceLabel = _workspaceLabel ?? agent?.workspaceId;
    final question = agent?.status == AgentStatus.blocked
        ? parsePromptOptions(_text)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(displayName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const SizedBox(width: 16),
                if (agent != null)
                  Chip(
                    avatar: Icon(
                      Icons.circle,
                      color: statusColor(agent.status),
                      size: 12,
                    ),
                    label: Text('${agent.status.name} · $workspaceLabel'),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_workspaceLabelError != null)
            MaterialBanner(
              content: Text(_workspaceLabelError!),
              actions: [
                TextButton(
                  onPressed: _retryWorkspaceLabel,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.topLeft,
                child: SelectableText(
                  stripTuiChrome(_text),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                ),
              ),
            ),
          ),
          if (question != null)
            _PromptCard(
              question: question,
              onSend: _send,
              client: widget.client,
              paneId: widget.paneId,
            ),
          _QuickChipsRow(
            sending: _sending,
            onSend: _send,
            client: widget.client,
            paneId: widget.paneId,
          ),
          _Composer(
            controller: _messageController,
            sending: _sending,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.question,
    required this.onSend,
    required this.client,
    required this.paneId,
  });

  final PromptQuestion question;
  final Future<bool> Function(Future<void> Function()) onSend;
  final HerdrClient client;
  final String paneId;

  Widget _optionButton(PromptOption option) {
    void press() => onSend(() => client.prompt(paneId, '${option.number}'));
    final label = Text(
      '${option.number}. ${option.label}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return option.selected
        ? FilledButton(onPressed: press, child: label)
        : FilledButton.tonal(onPressed: press, child: label);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (question.question != null) ...[
              Text(
                question.question!,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in question.options) _optionButton(option),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickChipsRow extends StatelessWidget {
  const _QuickChipsRow({
    required this.sending,
    required this.onSend,
    required this.client,
    required this.paneId,
  });

  final bool sending;
  final Future<bool> Function(Future<void> Function()) onSend;
  final HerdrClient client;
  final String paneId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        spacing: 8,
        children: [
          ActionChip(
            label: const Text('y'),
            onPressed: sending
                ? null
                : () => onSend(() => client.prompt(paneId, 'y')),
          ),
          ActionChip(
            label: const Text('n'),
            onPressed: sending
                ? null
                : () => onSend(() => client.prompt(paneId, 'n')),
          ),
          ActionChip(
            label: const Text('Enter'),
            onPressed: sending
                ? null
                : () => onSend(() => client.sendKeys(paneId, 'enter')),
          ),
          ActionChip(
            label: const Text('Esc'),
            onPressed: sending
                ? null
                : () => onSend(() => client.sendKeys(paneId, 'esc')),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !sending,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Message agent…',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: sending ? null : onSend,
          ),
        ],
      ),
    );
  }
}
