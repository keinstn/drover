import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../herdr/ansi_text.dart';
import '../herdr/herdr_client.dart';
import '../herdr/pane_text.dart';
import '../i18n/status_label.dart';
import '../image/image_input.dart';
import '../models/agent_info.dart';
import '../speech/speech_input.dart';
import '../transcript/native_transcript.dart';
import '../widgets/top_toast.dart';
import 'herd_screen.dart' show statusColor;

// The transcript renders on a fixed dark surface regardless of app theme:
// agent output carries absolute (truecolor) colours picked for a dark
// terminal, so a dark panel keeps them faithful and legible.
const _transcriptBg = Color(0xFF1B1B1F);
const _transcriptFg = Color(0xFFE4E4E7);

const _tailLines = 120; // lines fetched on the live poll / first load
const _lineStep = 240; // extra lines added per pull-to-load-more
const _maxPaneLines = 1000; // herdr's `recent` buffer is finite

String? _liveTerminalText(String paneText, NativeTranscript? nativeHistory) {
  if (nativeHistory == null || nativeHistory.messages.isEmpty) {
    return paneText;
  }
  final nativeText = nativeHistory.messages
      .map((message) => message.text)
      .join('\n');
  final lines = paneText
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final duplicateLines = lines
      .where((line) => line.length > 8 && nativeText.contains(line))
      .length;
  // The pane is retained for mode/prompt parsing, but not rendered when most
  // of it is already represented by the structured native conversation.
  if (lines.isNotEmpty && duplicateLines * 2 >= lines.length) {
    return null;
  }
  return paneText;
}

/// Detail screen for a single agent's pane: a live transcript, quick actions,
/// and a message composer.
class AgentScreen extends StatefulWidget {
  const AgentScreen({
    super.key,
    required this.client,
    required this.paneId,
    this.initialAgent,
    this.initialWorkspaceLabel,
    this.speechInput,
    this.imagePicker,
    this.pollInterval = const Duration(seconds: 2),
  });

  final HerdrClient client;
  final String paneId;
  final AgentInfo? initialAgent;
  final String? initialWorkspaceLabel;
  final SpeechInput? speechInput;
  final ImagePickerPort? imagePicker;
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
  NativeTranscript? _nativeHistory;
  String? _nativeHistorySessionIdentity;
  String? _nativeHistoryError;
  bool _paneEndReached = false;
  bool _dictationStarting = false;
  bool _dictating = false;
  String? _workspaceLabel;
  String? _workspaceLabelError;
  final List<PickedImage> _pendingImages = [];
  Timer? _timer;
  int _lines = _tailLines;

  final _scrollController = ScrollController();
  final _messageController = TextEditingController();
  late final SpeechInput _speechInput;
  late final ImagePickerPort _imagePicker;
  late final NativeTranscriptHistory _nativeTranscriptHistory;
  var _dictationSession = 0;
  var _draftBeforeDictation = '';

  @override
  void initState() {
    super.initState();
    _speechInput = widget.speechInput ?? SpeechInputController();
    _imagePicker = widget.imagePicker ?? SystemImagePicker();
    _nativeTranscriptHistory = NativeTranscriptHistory(widget.client.runner);
    _agent = widget.initialAgent;
    _workspaceLabel = widget.initialWorkspaceLabel;
    _load();
    if (_agent != null && _workspaceLabel == null) _loadWorkspaceLabel();
    _timer = Timer.periodic(widget.pollInterval, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_dictationStarting || _dictating) {
      unawaited(_speechInput.cancel());
    }
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

  Future<void> _load({bool loadMore = false}) async {
    if (_loading) return;
    _loading = true;
    final stickToBottom = !loadMore && (_firstLoad || _wasAtBottom);
    final anchorFromBottom = loadMore && _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent -
              _scrollController.position.pixels
        : null;
    try {
      final agent = await widget.client.getAgent(widget.paneId);
      final nativeHistorySessionIdentity =
          NativeTranscriptHistory.sessionIdentityFor(agent);
      final nativeHistorySessionChanged =
          nativeHistorySessionIdentity != _nativeHistorySessionIdentity;
      NativeTranscript? nativeHistory;
      String? nativeHistoryError;
      try {
        nativeHistory = await _nativeTranscriptHistory.load(agent);
      } catch (e) {
        nativeHistoryError = e.toString();
      }
      final text = await widget.client.readAgent(widget.paneId, lines: _lines);
      if (!mounted) return;
      final paneEndReached =
          loadMore && (text == _text || _lines >= _maxPaneLines);
      setState(() {
        _agent = agent;
        _text = text;
        _nativeHistory =
            nativeHistoryError != null && !nativeHistorySessionChanged
            ? _nativeHistory
            : nativeHistory;
        _nativeHistorySessionIdentity = nativeHistorySessionIdentity;
        _nativeHistoryError = nativeHistoryError;
        if (paneEndReached) {
          _paneEndReached = true;
        }
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
      } else if (anchorFromBottom != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          final target =
              (_scrollController.position.maxScrollExtent - anchorFromBottom)
                  .clamp(0.0, _scrollController.position.maxScrollExtent);
          _scrollController.jumpTo(target);
        });
      }
    } catch (_) {
      // Keep last known state on read/poll errors; the transcript stays
      // visible and the next tick will retry.
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadMore() async {
    if ((_nativeHistory?.messages.isNotEmpty ?? false) || _paneEndReached) {
      return;
    }
    setState(() => _lines = min(_maxPaneLines, _lines + _lineStep));
    await _load(loadMore: true);
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

  /// Sends the composer's text and any staged images together. With staged
  /// images the whole turn goes through [HerdrClient.sendImages] (caption +
  /// paths); otherwise it's a plain text prompt.
  Future<void> _sendMessage() async {
    if (_dictationStarting || _dictating) return;
    final text = _messageController.text;
    if (_pendingImages.isEmpty && text.trim().isEmpty) return;
    final agent = _agent;
    if (_pendingImages.isNotEmpty && agent == null) {
      return; // need the agent's cwd first
    }
    final ok = await _send(
      () => _pendingImages.isEmpty
          ? widget.client.prompt(widget.paneId, text)
          : widget.client.sendImages(
              agent!,
              images: _pendingImages,
              caption: text,
            ),
    );
    if (ok) {
      _messageController.clear();
      HapticFeedback.lightImpact();
      if (mounted) setState(() => _pendingImages.clear());
    }
  }

  /// Picks an image from [source] and stages it in the composer. It isn't sent
  /// until the user taps send, so it goes out together with whatever text they
  /// type.
  Future<void> _attachImage(ImageAttachSource source) async {
    if (_sending || _dictationStarting || _dictating) return;
    try {
      if (source == ImageAttachSource.camera) {
        final picked = await _imagePicker.pickImage(source);
        if (picked == null) return; // user cancelled
        if (mounted) setState(() => _pendingImages.add(picked));
      } else {
        final picked = await _imagePicker.pickImages();
        if (picked.isEmpty) return; // user cancelled
        if (mounted) setState(() => _pendingImages.addAll(picked));
      }
    } catch (e) {
      if (mounted) showTopToast(context, e.toString());
    }
  }

  void _removePendingImage(int index) =>
      setState(() => _pendingImages.removeAt(index));

  Future<void> _toggleDictation() async {
    if (_dictating) {
      try {
        await _speechInput.stop();
      } catch (error) {
        if (mounted) showTopToast(context, error.toString());
      }
      return;
    }
    if (_dictationStarting) return;

    final session = ++_dictationSession;
    _draftBeforeDictation = _messageController.text;
    setState(() => _dictationStarting = true);
    final result = await _speechInput.start(
      onResult: (result) => _applyDictationResult(session, result),
      onStatus: (status) => _handleDictationStatus(session, status),
      onError: (message) => _handleDictationError(session, message),
    );
    if (!mounted || session != _dictationSession) return;
    if (!result.started) {
      setState(() => _dictationStarting = false);
      showTopToast(context, result.errorMessage!);
      return;
    }
    setState(() {
      _dictationStarting = false;
      _dictating = true;
    });
  }

  void _applyDictationResult(int session, SpeechInputResult result) {
    if (!mounted || session != _dictationSession) return;
    final spoken = result.words.trim();
    final separator =
        _draftBeforeDictation.isNotEmpty &&
            !RegExp(r'\s$').hasMatch(_draftBeforeDictation)
        ? ' '
        : '';
    final text = spoken.isEmpty
        ? _draftBeforeDictation
        : '$_draftBeforeDictation$separator$spoken';
    _messageController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleDictationStatus(int session, SpeechInputStatus status) {
    if (!mounted ||
        session != _dictationSession ||
        status != SpeechInputStatus.done) {
      return;
    }
    setState(() {
      _dictationStarting = false;
      _dictating = false;
    });
  }

  void _handleDictationError(int session, String message) {
    if (!mounted || session != _dictationSession) return;
    setState(() {
      _dictationStarting = false;
      _dictating = false;
    });
    showTopToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final agent = _agent;
    final displayName = agent?.name ?? agent?.agent ?? widget.paneId;
    final workspaceLabel = _workspaceLabel ?? agent?.workspaceId;
    final plain = stripAnsi(_text);
    final question = agent?.status == AgentStatus.blocked
        ? parsePromptOptions(plain)
        : null;
    final mode = parseAgentMode(plain);
    final nativeHistory = _nativeHistory;
    final paneText = stripTuiChrome(_text);
    final liveTerminalText = _liveTerminalText(paneText, nativeHistory);

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
                    label: Text(
                      '${agentStatusLabel(l10n, agent.status)} · $workspaceLabel',
                    ),
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
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          if (_nativeHistoryError != null)
            MaterialBanner(
              content: Text(l10n.agentNativeHistoryError(_nativeHistoryError!)),
              actions: [
                TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
              ],
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              color: _transcriptBg,
              child: RefreshIndicator(
                onRefresh: _loadMore,
                child: SingleChildScrollView(
                  key: const ValueKey('transcript_scroll'),
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (nativeHistory != null) ...[
                        _TranscriptSectionLabel(label: l10n.agentNativeHistory),
                        _NativeTranscript(messages: nativeHistory.messages),
                      ],
                      if (liveTerminalText != null &&
                          liveTerminalText.trim().isNotEmpty) ...[
                        if (nativeHistory != null) const SizedBox(height: 20),
                        if (nativeHistory != null)
                          _TranscriptSectionLabel(
                            label: l10n.agentLiveTerminal,
                          ),
                        _Transcript(ansiText: liveTerminalText),
                      ],
                      if (nativeHistory == null && _paneEndReached) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.agentHistoryBeginning,
                          style: const TextStyle(
                            color: _transcriptFg,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
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
          _Composer(
            controller: _messageController,
            sending: _sending,
            dictationStarting: _dictationStarting,
            dictating: _dictating,
            agentRunning: agent?.status == AgentStatus.working,
            pendingImages: _pendingImages,
            onRemoveImage: _removePendingImage,
            onDictation: _toggleDictation,
            onAttach: _attachImage,
            onSend: _sendMessage,
            mode: mode,
            onAction: _send,
            client: widget.client,
            paneId: widget.paneId,
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

class _TranscriptSectionLabel extends StatelessWidget {
  const _TranscriptSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: const TextStyle(
          color: _transcriptFg,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _NativeTranscript extends StatelessWidget {
  const _NativeTranscript({required this.messages});

  final List<TranscriptMessage> messages;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final message in messages)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: message.speaker == TranscriptSpeaker.user
                  ? const Color(0xFF30363D)
                  : const Color(0xFF22252B),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              message.text,
              style: const TextStyle(
                color: _transcriptFg,
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ),
      ],
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.dictationStarting,
    required this.dictating,
    required this.agentRunning,
    required this.pendingImages,
    required this.onRemoveImage,
    required this.onDictation,
    required this.onAttach,
    required this.onSend,
    required this.mode,
    required this.onAction,
    required this.client,
    required this.paneId,
  });

  final TextEditingController controller;
  final bool sending;
  final bool dictationStarting;
  final bool dictating;

  /// Whether the agent is actively processing. When it is and the input is
  /// empty, the send button becomes a stop button that interrupts with Esc.
  final bool agentRunning;
  final List<PickedImage> pendingImages;
  final void Function(int index) onRemoveImage;
  final VoidCallback onDictation;
  final void Function(ImageAttachSource source) onAttach;
  final VoidCallback onSend;
  final AgentMode? mode;

  /// Wraps client actions (mode cycling, Enter, Esc) so the caller can track
  /// in-flight sends.
  ///
  /// The mode chip is tappable: tapping it cycles the agent's mode by
  /// sending the raw backtab escape sequence via `client.cycleMode`, since
  /// herdr's `send-keys shift+tab` mis-encodes it for kitty-keyboard agents
  /// like Claude Code (see herdr issue #1561). This can only cycle through
  /// modes, not jump to a specific one.
  final Future<bool> Function(Future<void> Function()) onAction;
  final HerdrClient client;
  final String paneId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final mode = this.mode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pendingImages.isNotEmpty) ...[
              SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: pendingImages.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _PendingImagePreview(
                    image: pendingImages[index],
                    onRemove: sending ? null : () => onRemoveImage(index),
                    index: index,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: controller,
              enabled: !sending && !dictationStarting && !dictating,
              minLines: 1,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: l10n.agentComposerHint,
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AttachButton(
                  sending: sending || dictationStarting || dictating,
                  onPick: onAttach,
                ),
                if (mode != null) ...[
                  const SizedBox(width: 8),
                  _ModeButton(
                    mode: mode,
                    sending: sending,
                    onPressed: () => onAction(() => client.cycleMode(paneId)),
                  ),
                ],
                const Spacer(),
                _MicrophoneButton(
                  starting: dictationStarting,
                  dictating: dictating,
                  onPressed: onDictation,
                ),
                const SizedBox(width: 8),
                _SendButton(
                  controller: controller,
                  busy: sending || dictationStarting || dictating,
                  agentRunning: agentRunning,
                  hasPendingImages: pendingImages.isNotEmpty,
                  onSend: onSend,
                  onStop: () => onAction(() => client.sendKeys(paneId, 'esc')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A single staged image thumbnail sitting in the composer's horizontal
/// strip, shown above the input row until the user sends it with their
/// message (or removes it via [onRemove], which is null while a send is in
/// flight). [index] is this item's position in the strip, used to give its
/// remove button a unique key.
class _PendingImagePreview extends StatelessWidget {
  const _PendingImagePreview({
    required this.image,
    required this.onRemove,
    required this.index,
  });

  final PickedImage image;
  final VoidCallback? onRemove;
  final int index;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        children: [
          Positioned(
            left: 4,
            top: 8,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                image.bytes,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: IconButton(
              key: ValueKey('remove_image_button_$index'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              tooltip: l10n.agentRemoveImage,
              icon: const Icon(Icons.cancel, size: 18),
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.sending, required this.onPick});

  final bool sending;
  final void Function(ImageAttachSource source) onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: 48,
      height: 48,
      child: Tooltip(
        message: l10n.agentAttachImage,
        child: OutlinedButton(
          key: const ValueKey('attach_image_button'),
          onPressed: sending ? null : () => _handleTap(context),
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
          ),
          child: const Icon(Icons.add, size: 22),
        ),
      ),
    );
  }

  Future<void> _handleTap(BuildContext context) async {
    // Camera capture is iOS-only (image_picker has no camera source on macOS).
    // Without a choice to make, go straight to the photo library.
    if (Theme.of(context).platform != TargetPlatform.iOS) {
      onPick(ImageAttachSource.gallery);
      return;
    }
    final source = await _showSourceSheet(context);
    if (source != null) onPick(source);
  }

  Future<ImageAttachSource?> _showSourceSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return showModalBottomSheet<ImageAttachSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('attach_from_library'),
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.agentAttachFromLibrary),
              onTap: () => Navigator.of(context).pop(ImageAttachSource.gallery),
            ),
            ListTile(
              key: const ValueKey('attach_from_camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(l10n.agentAttachFromCamera),
              onTap: () => Navigator.of(context).pop(ImageAttachSource.camera),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.sending,
    required this.onPressed,
  });

  final AgentMode mode;
  final bool sending;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = _modeColor(mode);
    return SizedBox(
      width: 48,
      height: 48,
      child: Tooltip(
        message: l10n.agentCycleModeTooltip,
        child: OutlinedButton(
          key: const ValueKey('cycle_mode_button'),
          onPressed: sending ? null : onPressed,
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            foregroundColor: color,
            side: BorderSide(color: color),
          ),
          child: const Icon(Icons.tune, size: 20),
        ),
      ),
    );
  }
}

class _MicrophoneButton extends StatelessWidget {
  const _MicrophoneButton({
    required this.starting,
    required this.dictating,
    required this.onPressed,
  });

  final bool starting;
  final bool dictating;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = !starting;
    return SizedBox(
      width: 48,
      height: 48,
      child: Tooltip(
        message: dictating ? l10n.agentStopDictation : l10n.agentDictateMessage,
        child: OutlinedButton(
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
          ),
          child: starting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(dictating ? Icons.stop : Icons.mic, size: 20),
        ),
      ),
    );
  }
}

/// The composer's primary action button. It shows a spinner while [busy]
/// (a send/attach is in flight or dictation is active), a stop button when the
/// agent is running and there is nothing staged to send — no text and no
/// pending images (tapping it interrupts with Esc via [onStop]), and otherwise
/// a send button ([onSend]).
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.controller,
    required this.busy,
    required this.agentRunning,
    required this.hasPendingImages,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool busy;
  final bool agentRunning;
  final bool hasPendingImages;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: 48,
      height: 48,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final showStop =
              agentRunning && !hasPendingImages && value.text.trim().isEmpty;
          final button = FilledButton(
            key: const ValueKey('send_message_button'),
            onPressed: busy ? null : (showStop ? onStop : onSend),
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(showStop ? Icons.stop : Icons.arrow_upward, size: 20),
          );
          if (!busy && showStop) {
            return Tooltip(message: l10n.agentStopAgent, child: button);
          }
          return button;
        },
      ),
    );
  }
}
