import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../herdr/ansi_text.dart';
import '../herdr/herdr_client.dart';
import '../herdr/pane_text.dart';
import '../models/agent_info.dart';
import '../widgets/top_toast.dart';
import 'herd_screen.dart' show statusColor;

// The transcript renders on a fixed dark surface regardless of app theme:
// agent output carries absolute (truecolor) colours picked for a dark
// terminal, so a dark panel keeps them faithful and legible.
const _transcriptBg = Color(0xFF1B1B1F);
const _transcriptFg = Color(0xFFE4E4E7);

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
        showTopToast(context, e.toString());
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
    if (ok) {
      _messageController.clear();
      HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    final displayName = agent?.name ?? agent?.agent ?? widget.paneId;
    final workspaceLabel = _workspaceLabel ?? agent?.workspaceId;
    final plain = stripAnsi(_text);
    final question = agent?.status == AgentStatus.blocked
        ? parsePromptOptions(plain)
        : null;
    final mode = parseAgentMode(plain);

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
            child: Container(
              width: double.infinity,
              color: _transcriptBg,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                child: _Transcript(ansiText: stripTuiChrome(_text)),
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
          _ActionBar(
            mode: mode,
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

/// Renders ANSI-coloured transcript text as selectable rich text over the dark
/// transcript surface.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.ansiText});

  final String ansiText;

  @override
  Widget build(BuildContext context) {
    final spans = parseAnsi(ansiText);
    return Align(
      alignment: Alignment.topLeft,
      child: SelectableText.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13.5,
            height: 1.4,
            color: _transcriptFg,
          ),
          children: [
            for (final span in spans)
              TextSpan(
                text: span.text,
                style: TextStyle(
                  color: span.color,
                  fontWeight: span.bold ? FontWeight.bold : null,
                ),
              ),
          ],
        ),
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

Color _modeColor(AgentMode mode) {
  switch (mode) {
    case AgentMode.normal:
      return Colors.blueGrey;
    case AgentMode.autoAccept:
      return Colors.amber.shade700;
    case AgentMode.plan:
      return Colors.blue;
    case AgentMode.bypass:
      return Colors.red;
  }
}

/// A mode indicator (shown when the agent reports one) plus the common
/// Enter/Esc keys.
///
/// The mode chip is tappable: tapping it cycles the agent's mode by sending
/// the raw backtab escape sequence via `client.cycleMode`, since herdr's
/// `send-keys shift+tab` mis-encodes it for kitty-keyboard agents like Claude
/// Code (see herdr issue #1561). This can only cycle through modes, not jump
/// to a specific one.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.mode,
    required this.sending,
    required this.onSend,
    required this.client,
    required this.paneId,
  });

  final AgentMode? mode;
  final bool sending;
  final Future<bool> Function(Future<void> Function()) onSend;
  final HerdrClient client;
  final String paneId;

  @override
  Widget build(BuildContext context) {
    final mode = this.mode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          if (mode != null)
            Flexible(
              child: Tooltip(
                message: 'Cycle agent mode (shift+tab)',
                child: ActionChip(
                  avatar: Icon(Icons.tune, size: 18, color: _modeColor(mode)),
                  label: Text(mode.label, overflow: TextOverflow.ellipsis),
                  side: BorderSide(color: _modeColor(mode)),
                  visualDensity: VisualDensity.compact,
                  onPressed: sending
                      ? null
                      : () => onSend(() => client.cycleMode(paneId)),
                ),
              ),
            ),
          const Spacer(),
          ActionChip(
            label: const Text('Enter'),
            onPressed: sending
                ? null
                : () => onSend(() => client.sendKeys(paneId, 'enter')),
          ),
          const SizedBox(width: 8),
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
    final scheme = Theme.of(context).colorScheme;
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
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Message agent…',
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(sending: sending, onSend: onSend),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.sending, required this.onSend});

  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: FilledButton(
        onPressed: sending ? null : onSend,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        child: sending
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send, size: 20),
      ),
    );
  }
}
