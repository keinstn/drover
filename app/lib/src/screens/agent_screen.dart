import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark-dimmed.dart';

import '../../l10n/app_localizations.dart';
import '../agents/agent_capabilities.dart';
import '../agents/agent_native_history.dart';
import '../agents/agent_registry.dart';
import '../app_theme.dart';
import '../herdr/ansi_text.dart';
import '../herdr/herdr_client.dart';
import '../herdr/pane_text.dart';
import '../image/image_input.dart';
import '../models/agent_info.dart';
import '../speech/speech_input.dart';
import '../transcript/native_transcript.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/error_message_view.dart';
import '../widgets/status_pill.dart';
import '../widgets/text_context_menu.dart';
import '../widgets/top_toast.dart';
import 'agent_draft_store.dart';
import 'structured_prompt_sheet.dart';

// The transcript renders on a fixed dark surface regardless of app theme:
// agent output carries absolute (truecolor) colours picked for a dark
// terminal, so a dark panel keeps them faithful and legible.
const _transcriptBg = Color(0xFF1B1B1F);
const _transcriptFg = Color(0xFFE4E4E7);
// Dimmed foreground for secondary rows (tool-use summaries, thinking blocks)
// that should read as quieter than the main conversation text.
const _transcriptFgDim = Color(0xFF8B8B92);
// Panel behind inline/fenced code, a touch lighter than the transcript surface
// so code stays legible without the pure-white background of light themes.
const _codeSurface = Color(0xFF26262B);
// Muted diff tints painted over _codeSurface: low-chroma red/green (~20% alpha)
// that stay calm on the dark Ink surface.
const _diffRemoveBg = Color(0x33F85149);
const _diffAddBg = Color(0x333FB950);

// Base style for fenced code: kept in sync with the plain-text fallback so
// highlighted and unhighlighted blocks read identically apart from colour.
const _codeTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 13,
  height: 1.4,
  color: _transcriptFg,
);

// UI-side highlighter, used only for the cheap getLanguage() pre-check that
// decides whether a fence tag is worth highlighting. The actual highlight()
// call is expensive (seconds on pathological input) and runs off the UI
// isolate — see _highlightSegments.
final Highlight _codeHighlighter = Highlight()
  ..registerLanguages(builtinLanguages);

// Above this the highlight cost isn't worth it; such blocks render plain.
const _maxHighlightChars = 20000;

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
    this.initialAgents = const [],
    this.initialWorkspaceLabel,
    this.speechInput,
    this.imagePicker,
    this.draftStore,
    this.nativeTranscriptHistory,
    this.nativeHistoryResolver,
    this.pollInterval = const Duration(seconds: 2),
  });

  final HerdrClient client;
  final String paneId;
  final AgentInfo? initialAgent;

  /// The caller's last known agent list, seeding the switcher bar before the
  /// first `listAgents` poll lands. Without it a bar-driven switch would mount
  /// the replacement screen with an empty list — collapsing the bar for one
  /// SSH round-trip and re-playing its entrance on the very interaction the
  /// bar exists to make seamless.
  final List<AgentInfo> initialAgents;
  final String? initialWorkspaceLabel;
  final SpeechInput? speechInput;
  final ImagePickerPort? imagePicker;
  final AgentDraftStore? draftStore;
  // A pane-scoped history/loader instance the caller (e.g. `HerdScreen`'s
  // per-pane cache) may inject so reopening the same pane resumes from its
  // already-loaded window/offset state instead of starting from zero. When
  // omitted (standalone use, previews, tests) a fresh instance is created
  // per screen instance, matching the pre-cache behavior.
  final NativeTranscriptHistory? nativeTranscriptHistory;

  /// Resolves a pane-scoped [NativeTranscriptHistory] for an arbitrary pane id,
  /// so switching agents via the bottom switcher bar can reuse the caller's
  /// per-pane history cache (e.g. `HerdScreen`'s). When provided, a bar switch
  /// passes `nativeHistoryResolver(paneId)` as the next screen's history and
  /// forwards the resolver; when null the next screen builds its own (the
  /// existing standalone/preview/test default).
  final NativeTranscriptHistory Function(String paneId)? nativeHistoryResolver;
  final Duration pollInterval;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  AgentInfo? _agent;
  // All running agents from the latest `listAgents()` poll (seeded from
  // `widget.initialAgents`), used to derive the current agent (by pane id)
  // and to drive the bottom switcher bar.
  late List<AgentInfo> _agents = widget.initialAgents;
  String _text = '';
  bool _loading = false;
  bool _firstLoad = true;
  bool _sending = false;
  bool _workspaceLabelLoading = false;
  NativeTranscript? _nativeHistory;
  String? _nativeHistorySessionIdentity;
  Object? _nativeHistoryError;
  bool _nativeHistoryLoading = false;
  Object? _loadError;
  bool _paneEndReached = false;
  bool _dictationStarting = false;
  bool _dictating = false;
  String? _workspaceLabel;
  Object? _workspaceLabelError;
  final List<PickedImage> _pendingImages = [];
  Timer? _timer;
  int _lines = _tailLines;
  // Whether the structured-prompt sheet is currently on screen, and the
  // prompt id it was opened for. The id is retained after the sheet closes so
  // the 2s poll never re-opens the sheet for the same prompt (once-only
  // presentation).
  bool _structuredPromptSheetOpen = false;
  String? _shownStructuredPromptId;
  // The pushed sheet's route, so an auto-dismiss only pops when that route is
  // still current (never the AgentScreen route beneath it).
  ModalRoute<void>? _structuredPromptSheetRoute;

  final _scrollController = ScrollController();
  final _messageController = TextEditingController();
  late final SpeechInput _speechInput;
  late final ImagePickerPort _imagePicker;
  late final AgentDraftStore _draftStore;
  late final NativeTranscriptHistory _nativeTranscriptHistory;
  var _dictationSession = 0;
  var _draftBeforeDictation = '';

  @override
  void initState() {
    super.initState();
    _speechInput = widget.speechInput ?? SpeechInputController();
    _imagePicker = widget.imagePicker ?? SystemImagePicker();
    _draftStore = widget.draftStore ?? AgentDraftStore.shared;
    _nativeTranscriptHistory =
        widget.nativeTranscriptHistory ??
        NativeTranscriptHistory(
          widget.client.runner,
          platform: widget.client.hostPlatform,
        );
    // Restore any draft left over from a previous visit to this pane's screen
    // (the route is popped/re-pushed on navigation, disposing the controller).
    final draft = _draftStore.read(widget.paneId);
    if (draft != null) {
      _messageController.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
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
    // Persist the in-progress draft before the controller is torn down so it
    // survives navigating away from and back to this pane.
    _draftStore.write(widget.paneId, _messageController.text);
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  bool get _wasAtBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 40;
  }

  /// Applies a scroll restoration after the slivers have received their new
  /// geometry. A second frame accounts for a lazy list refining its estimated
  /// extent once it lays out children around the first target. It only runs
  /// while the first jump remains in place, so a user scroll between frames is
  /// never overridden.
  void _restoreScrollAfterLayout({
    bool stickToBottom = false,
    double? anchorFromBottom,
  }) {
    if (!stickToBottom && anchorFromBottom == null) return;

    double targetFor(ScrollPosition position) => stickToBottom
        ? position.maxScrollExtent
        : (position.maxScrollExtent - anchorFromBottom!)
              .clamp(0.0, position.maxScrollExtent)
              .toDouble();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final firstTarget = targetFor(position);
      if ((position.pixels - firstTarget).abs() > 0.5) {
        _scrollController.jumpTo(firstTarget);
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final settledPosition = _scrollController.position;
        // Do not turn a user gesture that lands between the two layout passes
        // into an unexpected snap to the old target.
        if ((settledPosition.pixels - firstTarget).abs() > 0.5) return;
        final settledTarget = targetFor(settledPosition);
        if ((settledPosition.pixels - settledTarget).abs() > 0.5) {
          _scrollController.jumpTo(settledTarget);
        }
      });
    });
  }

  /// The resolved agent-specific capabilities for [_agent], or null when the
  /// agent hasn't loaded yet, no adapter supports it, or the adapter doesn't
  /// implement that capability. AgentScreen only ever consumes capabilities
  /// through these getters — never a concrete agent implementation — so
  /// unsupported functionality is hidden or falls back to the generic
  /// pane-text behavior instead of throwing.
  AgentModeCapability? get _modeCapability {
    final agent = _agent;
    return agent == null ? null : resolveAgentAdapter(agent)?.mode;
  }

  StructuredPromptCapability? get _structuredPrompt {
    final agent = _agent;
    return agent == null ? null : resolveAgentAdapter(agent)?.structuredPrompt;
  }

  ImageAttachmentCapability? get _imagesCapability {
    final agent = _agent;
    return agent == null ? null : resolveAgentAdapter(agent)?.images;
  }

  /// Delivers a plain-text prompt, routing through the resolved agent
  /// adapter's [AgentAdapter.deliverPrompt] when one exists (e.g. Copilot's
  /// background-focus workaround) or the generic [HerdrClient.prompt]
  /// otherwise.
  Future<void> _deliverPrompt(String text) {
    final agent = _agent;
    final adapter = agent == null ? null : resolveAgentAdapter(agent);
    return adapter?.deliverPrompt(widget.client, widget.paneId, text) ??
        widget.client.prompt(widget.paneId, text);
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
      setState(() => _workspaceLabelError = e);
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
      // Fetch and publish the fast pane path first: agent metadata and the
      // pane's own tail. Native transcript history (a locate/stat/read/parse
      // sequence over the same mutex-serialized SSH channel) can be much
      // slower, so it's kicked off separately below rather than awaited here
      // — a slow host must never leave the visible transcript blank.
      final agents = await widget.client.listAgents();
      final text = await widget.client.readAgent(widget.paneId, lines: _lines);
      if (!mounted) return;
      // Derive the current agent from the list by pane id. When this pane isn't
      // in the list (e.g. it just closed), keep the last known agent rather than
      // blanking the header/transcript; read failures still surface via the
      // catch below.
      final agent =
          agents.where((a) => a.paneId == widget.paneId).firstOrNull ?? _agent;
      final paneEndReached =
          loadMore && (text == _text || _lines >= _maxPaneLines);
      setState(() {
        _agents = agents;
        _agent = agent;
        _text = text;
        _loadError = null;
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
      _restoreScrollAfterLayout(
        stickToBottom: stickToBottom,
        anchorFromBottom: anchorFromBottom,
      );
      if (agent != null) unawaited(_loadNativeHistory(agent));
    } catch (e) {
      // Keep last known transcript content on read/poll errors, but surface
      // the failure so it isn't silently swallowed; the next tick, or the
      // banner's retry action, will try again.
      if (!mounted) return;
      setState(() => _loadError = e);
    } finally {
      _loading = false;
    }
  }

  /// Loads native transcript history for [agent] and publishes it
  /// independently of the pane-text fetch in [_load], so a slow native load
  /// never delays already-fetched pane output.
  ///
  /// Single-flights against itself (and against `_loadOlderNativeHistory`,
  /// which shares the same `_nativeHistoryLoading` flag): the underlying
  /// adapter keeps incremental parse state (byte offset, partial line) that
  /// isn't safe to touch from two overlapping loads — e.g. a poll's
  /// truncation-triggered reset racing a pull-to-load-more's read — so a
  /// poll tick that lands while a previous native load (of either kind) is
  /// still in flight simply skips starting another one — the next tick
  /// retries. This preserves the same effective serialization the previous
  /// fully-sequential `_load` gave native history for free.
  Future<void> _loadNativeHistory(AgentInfo agent) async {
    if (_nativeHistoryLoading) return;
    _nativeHistoryLoading = true;
    final stickToBottom = _wasAtBottom;
    try {
      final nativeHistorySessionIdentity =
          NativeTranscriptHistory.sessionIdentityFor(agent);
      final nativeHistorySessionChanged =
          nativeHistorySessionIdentity != _nativeHistorySessionIdentity;
      NativeTranscript? nativeHistory;
      Object? nativeHistoryError;
      try {
        nativeHistory = await _nativeTranscriptHistory.load(agent);
      } catch (e) {
        nativeHistoryError = e;
      }
      if (!mounted) return;
      setState(() {
        _nativeHistory =
            nativeHistoryError != null && !nativeHistorySessionChanged
            ? _nativeHistory
            : nativeHistory;
        _nativeHistorySessionIdentity = nativeHistorySessionIdentity;
        _nativeHistoryError = nativeHistoryError;
      });
      _restoreScrollAfterLayout(stickToBottom: stickToBottom);
      _syncStructuredPromptSheet();
    } finally {
      _nativeHistoryLoading = false;
    }
  }

  /// Reconciles the structured-prompt sheet with the latest poll.
  /// Auto-presents the sheet the first time a prompt is pending (tracked by
  /// its id so a later poll never re-opens it), and auto-dismisses an open
  /// sheet once its prompt is gone — answered elsewhere or the agent moved on.
  void _syncStructuredPromptSheet() {
    if (!mounted) return;
    final history = _nativeHistory;
    final pending = history == null
        ? null
        : _structuredPrompt?.pendingPrompt(history);
    if (_structuredPromptSheetOpen) {
      if (pending == null || pending.id != _shownStructuredPromptId) {
        // Clear the flag first so nothing else treats the sheet as open, then
        // only pop/toast if the sheet's route is genuinely still current — a
        // successful submit or user cancel pops the route itself, and its
        // ~250ms close animation would otherwise let this branch fire a second
        // pop (which could pop the AgentScreen) and a spurious toast.
        _structuredPromptSheetOpen = false;
        final route = _structuredPromptSheetRoute;
        _structuredPromptSheetRoute = null;
        if (route != null && route.isCurrent) {
          Navigator.of(context).pop();
          showTopToast(
            context,
            AppLocalizations.of(context)!.agentAskUserDismissed,
          );
        }
      }
      return;
    }
    if (pending != null && pending.id != _shownStructuredPromptId) {
      unawaited(_openStructuredPromptSheet(pending));
    }
  }

  Future<void> _openStructuredPromptSheet(StructuredPrompt prompt) async {
    _structuredPromptSheetOpen = true;
    _shownStructuredPromptId = prompt.id;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        _structuredPromptSheetRoute = ModalRoute.of(sheetContext);
        return StructuredPromptSheet(
          prompt: prompt,
          onSubmit: (answers) => _submitStructuredPrompt(prompt, answers),
        );
      },
    );
    _structuredPromptSheetOpen = false;
    _structuredPromptSheetRoute = null;
  }

  /// Submits the staged [answers] into the live TUI dialog via the resolved
  /// agent's structured-prompt capability. On failure the error is surfaced
  /// as a top toast and rethrown so the sheet stays open with its staged
  /// answers.
  Future<void> _submitStructuredPrompt(
    StructuredPrompt prompt,
    List<StructuredPromptAnswer> answers,
  ) async {
    try {
      await _structuredPrompt!.submit(
        client: widget.client,
        paneId: widget.paneId,
        prompt: prompt,
        answers: answers,
      );
      // The sheet pops itself on success. Clear the flag synchronously (before
      // that pop and any subsequent poll) so _syncStructuredPromptSheet
      // doesn't mistake the close for an auto-dismiss and double-pop / show
      // the dismissed toast.
      _structuredPromptSheetOpen = false;
    } catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        final message = error is StructuredPromptSubmitError
            ? error.message
            : errorHeadline(l10n, error);
        showTopToast(context, l10n.agentAskUserSubmitError(message));
      }
      rethrow;
    }
  }

  Future<void> _loadMore() async {
    // Gate on entries (not just chat messages) so a tool_use- or thinking-only
    // history counts, matching hasNativeHistory. Also dispatch whenever the
    // adapter itself still reports older history even with zero entries
    // currently loaded — an oversized last record can leave the current
    // native snapshot empty while there's still earlier, reachable history
    // to page into (see `JsonlTranscriptWindow`); without this, such a pane
    // would fall through to the (irrelevant) pane load-more path forever.
    final hasNativeEntries = _nativeHistory?.entries.isNotEmpty ?? false;
    if (hasNativeEntries || _nativeTranscriptHistory.hasOlderHistory) {
      // Native history exists: page further back into it instead of falling
      // back to the pane. `_loadOlderNativeHistory` itself no-ops once the
      // beginning of that history has been reached. The pane load-more path
      // below is reserved for when there is no native history to page
      // through at all.
      await _loadOlderNativeHistory();
      return;
    }
    if (_paneEndReached) {
      return;
    }
    setState(() => _lines = min(_maxPaneLines, _lines + _lineStep));
    await _load(loadMore: true);
  }

  /// Prepends the next older bounded chunk of native transcript history (see
  /// `NativeTranscriptHistory.loadOlder`), preserving the scroll position
  /// relative to the bottom of the currently visible content — the same
  /// anchor-from-bottom technique `_load`'s pane load-more uses — so the
  /// newly-prepended older entries push the viewport down without a visible
  /// jump. A no-op once the beginning of the native history has been reached
  /// (`hasOlderHistory` false) or before any agent/history has loaded.
  ///
  /// Shares the same `_nativeHistoryLoading` single-flight guard as
  /// `_loadNativeHistory`: both ultimately mutate the same underlying
  /// `JsonlTranscriptWindow` (byte offset/partial-line/window state), which
  /// is not safe to touch from two overlapping calls — e.g. a poll tick
  /// landing (and possibly resetting state after a detected truncation)
  /// while a pull-to-load-more is still awaiting its own read. A tick or
  /// pull that finds the flag already set simply skips this round; a poll
  /// tick retries on its next interval, and a skipped pull-to-load-more
  /// gesture leaves `hasOlderHistory` unchanged for the user to retry.
  Future<void> _loadOlderNativeHistory() async {
    final agent = _agent;
    if (agent == null ||
        !_nativeTranscriptHistory.hasOlderHistory ||
        _nativeHistoryLoading) {
      return;
    }
    _nativeHistoryLoading = true;
    final anchorFromBottom = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent -
              _scrollController.position.pixels
        : null;
    try {
      final updated = await _nativeTranscriptHistory.loadOlder(agent);
      if (!mounted || updated == null) return;
      setState(() => _nativeHistory = updated);
      _restoreScrollAfterLayout(anchorFromBottom: anchorFromBottom);
    } catch (e) {
      if (!mounted) return;
      setState(() => _nativeHistoryError = e);
    } finally {
      _nativeHistoryLoading = false;
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
        showTopToast(context, errorHeadline(AppLocalizations.of(context)!, e));
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Sends the composer's text and any staged images together. With staged
  /// images the whole turn goes through the resolved agent's
  /// [ImageAttachmentCapability] (caption + paths); otherwise it's a plain
  /// text prompt.
  Future<void> _sendMessage() async {
    if (_dictationStarting || _dictating) return;
    final text = _messageController.text;
    if (_pendingImages.isEmpty && text.trim().isEmpty) return;
    final agent = _agent;
    final images = _imagesCapability;
    if (_pendingImages.isNotEmpty && (agent == null || images == null)) {
      return; // need the agent's cwd and an image-capable adapter first
    }
    final ok = await _send(
      () => _pendingImages.isEmpty
          ? _deliverPrompt(text)
          : images!.send(
              widget.client,
              agent!,
              images: _pendingImages,
              caption: text,
              deliver: _deliverPrompt,
            ),
    );
    if (ok) {
      _messageController.clear();
      _draftStore.clear(widget.paneId);
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
      if (mounted) {
        showTopToast(context, errorHeadline(AppLocalizations.of(context)!, e));
      }
    }
  }

  void _removePendingImage(int index) =>
      setState(() => _pendingImages.removeAt(index));

  Future<void> _toggleDictation() async {
    if (_dictating) {
      try {
        await _speechInput.stop();
      } catch (error) {
        if (mounted) {
          showTopToast(
            context,
            errorHeadline(AppLocalizations.of(context)!, error),
          );
        }
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

  /// Replaces this screen with one for [target] (a bottom-bar switch),
  /// forwarding the shared collaborators and the native-history resolver so the
  /// new pane resumes from the caller's per-pane cache when one is provided.
  void _switchToAgent(AgentInfo target) {
    if (target.paneId == widget.paneId) return;
    final resolver = widget.nativeHistoryResolver;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AgentScreen(
          client: widget.client,
          paneId: target.paneId,
          initialAgent: target,
          initialAgents: _agents,
          speechInput: widget.speechInput,
          imagePicker: widget.imagePicker,
          draftStore: widget.draftStore,
          pollInterval: widget.pollInterval,
          nativeTranscriptHistory: resolver?.call(target.paneId),
          nativeHistoryResolver: resolver,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final agent = _agent;
    final displayName =
        agent?.sessionTitle ?? agent?.name ?? agent?.agent ?? widget.paneId;
    final workspaceLabel = _workspaceLabel ?? agent?.workspaceId;
    final agentType = agent?.agent ?? 'agent';
    final plain = stripAnsi(_text);
    final nativeHistory = _nativeHistory;
    final structuredPrompt = _structuredPrompt;
    // A pending structured prompt drives its own modal sheet; suppress the
    // pane-text _PromptCard for it so the two never render at once. Other
    // blocked states keep the _PromptCard unchanged.
    final hasPendingStructuredPrompt =
        nativeHistory != null &&
        structuredPrompt?.pendingPrompt(nativeHistory) != null;
    final question =
        agent?.status == AgentStatus.blocked && !hasPendingStructuredPrompt
        ? parsePromptOptions(plain)
        : null;
    final modeCapability = _modeCapability;
    final mode = modeCapability?.parseMode(plain);
    // An empty-but-present native history (e.g. every record filtered out) is
    // treated as absent: no section header, and the pane fallback keeps working.
    // A tool_use- or thinking-only history still counts, so key off entries.
    final hasNativeHistory =
        nativeHistory != null && nativeHistory.entries.isNotEmpty;
    final paneText = stripTuiChrome(_text);
    final liveTerminalText = _liveTerminalText(paneText, nativeHistory);
    // Neither the pane nor the native transcript have produced anything to
    // show yet: while the very first load is still in flight (and hasn't
    // already failed — that gets its own retryable banner below) show a
    // spinner instead of an indefinitely blank transcript surface.
    final hasTranscriptContent =
        hasNativeHistory ||
        (liveTerminalText != null && liveTerminalText.trim().isNotEmpty);
    final showInitialLoading =
        !hasTranscriptContent && _firstLoad && _loadError == null;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _AgentHeader(
              agentType: agentType,
              agentTypeForAvatar: agent?.agent,
              displayName: displayName,
              workspaceLabel: workspaceLabel,
              status: agent?.status,
            ),
            if (_workspaceLabelError != null)
              MaterialBanner(
                content: ErrorMessageView(_workspaceLabelError!),
                actions: [
                  TextButton(
                    onPressed: _retryWorkspaceLabel,
                    child: Text(l10n.commonRetry),
                  ),
                ],
              ),
            if (_loadError != null)
              MaterialBanner(
                content: ErrorMessageView(_loadError!),
                actions: [
                  TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
                ],
              ),
            if (_nativeHistoryError != null)
              MaterialBanner(
                content: ErrorMessageView(_nativeHistoryError!),
                actions: [
                  TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
                ],
              ),
            Expanded(
              child: Container(
                width: double.infinity,
                color: scheme.surfaceContainerLowest,
                child: showInitialLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          key: ValueKey('transcript_initial_loading'),
                          strokeWidth: 2,
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadMore,
                        child: CustomScrollView(
                          key: const ValueKey('transcript_scroll'),
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 12),
                            ),
                            if (hasNativeHistory) ...[
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: _TranscriptSectionLabel(
                                    label: l10n.agentNativeHistory,
                                  ),
                                ),
                              ),
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                sliver: _NativeTranscript(
                                  entries: nativeHistory.entries,
                                ),
                              ),
                            ],
                            if (liveTerminalText != null &&
                                liveTerminalText.trim().isNotEmpty) ...[
                              if (hasNativeHistory)
                                const SliverToBoxAdapter(
                                  child: SizedBox(height: 20),
                                ),
                              if (hasNativeHistory)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: _TranscriptSectionLabel(
                                      label: l10n.agentLiveTerminal,
                                    ),
                                  ),
                                ),
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: _Transcript(
                                    ansiText: liveTerminalText,
                                  ),
                                ),
                              ),
                            ],
                            if (!hasNativeHistory && _paneEndReached)
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  12,
                                  0,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: Text(
                                    l10n.agentHistoryBeginning,
                                    style: TextStyle(
                                      color: DroverColors.of(
                                        context,
                                      ).tertiaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 16),
                            ),
                          ],
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
              canAttachImages: _imagesCapability != null,
              onRemoveImage: _removePendingImage,
              onDictation: _toggleDictation,
              onAttach: _attachImage,
              onSend: _sendMessage,
              mode: mode,
              modeCapability: modeCapability,
              onAction: _send,
              client: widget.client,
              paneId: widget.paneId,
            ),
            _AgentSwitcherBar(
              agents: _agents,
              currentPaneId: widget.paneId,
              onSelect: _switchToAgent,
              onOpenHerd: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          ],
        ),
      ),
    );
  }
}

/// The screen header (replaces the AppBar): back chevron, agent avatar, the
/// two-line title/subtitle, and a status pill. Sits under the top safe-area
/// inset with a hairline bottom border.
class _AgentHeader extends StatelessWidget {
  const _AgentHeader({
    required this.agentType,
    required this.agentTypeForAvatar,
    required this.displayName,
    required this.workspaceLabel,
    required this.status,
  });

  final String agentType;
  final String? agentTypeForAvatar;
  final String displayName;
  final String? workspaceLabel;
  final AgentStatus? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('agent_back_button'),
            icon: const Icon(Icons.arrow_back_ios_new),
            color: scheme.primary,
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 4),
          AgentAvatar(agent: agentTypeForAvatar, size: 34, radius: 12),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '$agentType · ${workspaceLabel ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (status != null) ...[
            const SizedBox(width: 8),
            StatusPill(status: status!),
          ],
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
    // The live terminal keeps a fixed dark surface in both themes so ANSI
    // truecolor stays faithful; a rounded clip makes it read as a card on the
    // light transcript surface.
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _transcriptBg,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(12),
      child: Align(
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
        textAlign: TextAlign.center,
        style: TextStyle(
          color: DroverColors.of(context).tertiaryText,
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Renders the structured native conversation as a modern chat, in the order
/// Claude produced each entry: user turns as right-aligned bubbles, assistant
/// turns as full-width Markdown, tool invocations as collapsible chips, and
/// thinking blocks as dimmed one-line rows.
class _NativeTranscript extends StatelessWidget {
  const _NativeTranscript({required this.entries});

  final List<TranscriptEntry> entries;

  @override
  Widget build(BuildContext context) {
    // JsonlTranscriptWindow retains entry instances across polls and prepends
    // older instances rather than recreating the existing window. ObjectKey
    // therefore gives every parsed entry a stable identity without inventing
    // or exposing a transport-level transcript id. The index callback lets
    // SliverList move an existing element to its new index on prepend, keeping
    // expansion state with that entry instead of the former position.
    final indexByEntry = <TranscriptEntry, int>{
      for (final (index, entry) in entries.indexed) entry: index,
    };
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _NativeTranscriptEntry(
          key: ObjectKey(entries[index]),
          entry: entries[index],
        ),
        childCount: entries.length,
        findChildIndexCallback: (key) {
          final value = key is ObjectKey ? key.value : null;
          return value is TranscriptEntry ? indexByEntry[value] : null;
        },
      ),
    );
  }
}

class _NativeTranscriptEntry extends StatelessWidget {
  const _NativeTranscriptEntry({super.key, required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final taskCompleteSummary = switch (entry) {
      TranscriptToolUse(:final name, :final input) => _taskCompleteSummary(
        name,
        input,
      ),
      _ => null,
    };
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: switch (entry) {
          TranscriptMessage(:final speaker, :final text) =>
            speaker == TranscriptSpeaker.user
                ? _UserBubble(text: text, maxWidth: constraints.maxWidth * 0.8)
                : _AssistantMessage(text: text),
          TranscriptToolUse() when taskCompleteSummary != null =>
            _AssistantMessage(text: taskCompleteSummary),
          TranscriptToolUse(:final name, :final input) => _ToolUseChip(
            name: name,
            input: input,
          ),
          TranscriptThinking(:final text) => _ThinkingRow(text: text),
          // A tool_result marker is only used to detect an answered
          // structured prompt (e.g. Claude's AskUserQuestion); it has no
          // chat-visible rendering.
          TranscriptToolResult() => const SizedBox.shrink(),
        },
      ),
    );
  }
}

String? _taskCompleteSummary(String name, Map<String, dynamic> input) {
  if (name != 'task_complete') return null;
  final summary = input['summary'];
  if (summary is! String) return null;
  final trimmedSummary = summary.trim();
  return trimmedSummary.isEmpty ? null : trimmedSummary;
}

/// A compact, collapsible tool invocation: a single glyph + name + summary row
/// that expands to a detail panel (a diff card for Edit/Write, otherwise the
/// pretty-printed input). Stateful so the expansion survives the 2s poll.
class _ToolUseChip extends StatefulWidget {
  const _ToolUseChip({required this.name, required this.input});

  final String name;
  final Map<String, dynamic> input;

  @override
  State<_ToolUseChip> createState() => _ToolUseChipState();
}

class _ToolUseChipState extends State<_ToolUseChip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final summary = toolUseSummary(widget.name, widget.input);
    final colors = DroverColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: colors.toolSurface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.build, size: 14, color: colors.tertiaryText),
                  const SizedBox(width: 8),
                  Text(
                    widget.name,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: colors.tertiaryText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _toolUseDetail(widget.name, widget.input),
          ),
      ],
    );
  }
}

/// Picks the expanded detail for a tool_use: a diff card for Edit (old/new
/// strings) and Write (content as added lines), otherwise the pretty-printed
/// input. Wrong-shaped input for Edit/Write falls back to the JSON detail.
Widget _toolUseDetail(String name, Map<String, dynamic> input) {
  if (name == 'Edit') {
    final oldText = input['old_string'];
    final newText = input['new_string'];
    if (oldText is String && newText is String) {
      return _DiffCard(oldText: oldText, newText: newText);
    }
  } else if (name == 'Write') {
    final content = input['content'];
    if (content is String) {
      return _DiffCard(oldText: null, newText: content);
    }
  }
  return _JsonDetail(input: input);
}

/// The pretty-printed tool input on the code surface: horizontally scrollable
/// so long lines never overflow, and height-capped with an inner vertical
/// scroll so a large map never dominates the transcript. Stateful so the
/// (non-trivial) encode is cached across the 2s poll's rebuilds.
class _JsonDetail extends StatefulWidget {
  const _JsonDetail({required this.input});

  final Map<String, dynamic> input;

  @override
  State<_JsonDetail> createState() => _JsonDetailState();
}

class _JsonDetailState extends State<_JsonDetail> {
  late String _pretty = _encode(widget.input);

  static String _encode(Map<String, dynamic> input) {
    // Transcript input is untrusted: out-of-range JSON literals (e.g. 1e999)
    // decode to double.infinity/NaN, which the plain encoder rejects. The
    // toEncodable fallback stringifies whatever it can't serialise, and the
    // catch-all guards anything still unencodable so an expanded chip can never
    // become an ErrorWidget.
    try {
      return JsonEncoder.withIndent('  ', (o) => o.toString()).convert(input);
    } catch (_) {
      return input.toString();
    }
  }

  @override
  void didUpdateWidget(_JsonDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The loader keeps entry instances across polls, so the input map is a
    // stable instance; only re-encode when a genuinely different one lands.
    if (!identical(oldWidget.input, widget.input)) {
      _pretty = _encode(widget.input);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: _codeSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: Text(
            _pretty,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
              color: _transcriptFg,
            ),
          ),
        ),
      ),
    );
  }
}

/// A naive diff card: every old line (red-tinted, '-' gutter) then every new
/// line (green-tinted, '+' gutter) — no LCS. [oldText] is null for a Write.
/// Horizontally scrollable and height-capped with an inner vertical scroll.
class _DiffCard extends StatelessWidget {
  const _DiffCard({required this.oldText, required this.newText});

  final String? oldText;
  final String? newText;

  // A huge Write/Edit would otherwise build thousands of rows on every poll.
  // Cap the rendered lines and summarise the rest in a footer.
  static const _maxLines = 200;

  static List<String> _lines(String text) {
    final trimmed = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    return trimmed.split('\n');
  }

  Widget _line(String gutter, String text, Color background) {
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Text(
        '$gutter $text',
        softWrap: false,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.4,
          color: _transcriptFg,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final oldLines = oldText != null && oldText!.isNotEmpty
        ? _lines(oldText!)
        : const <String>[];
    final newLines = newText != null && newText!.isNotEmpty
        ? _lines(newText!)
        : const <String>[];
    final total = oldLines.length + newLines.length;
    final rows = <Widget>[];
    for (final line in oldLines) {
      if (rows.length >= _maxLines) break;
      rows.add(_line('-', line, _diffRemoveBg));
    }
    for (final line in newLines) {
      if (rows.length >= _maxLines) break;
      rows.add(_line('+', line, _diffAddBg));
    }
    if (total > _maxLines) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text(
            '… +${total - _maxLines} lines',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: _transcriptFgDim,
            ),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _codeSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // IntrinsicWidth stretches every row to the widest so the tints paint
          // a continuous block rather than ragged per-line rectangles.
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: rows,
            ),
          ),
        ),
      ),
    );
  }
}

/// A thinking block as a dimmed, italic one-line label that expands to the
/// full thinking text. Stateful so expansion survives the 2s poll; collapsed
/// by default.
class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow({required this.text});

  final String text;

  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tertiary = DroverColors.of(context).tertiaryText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              l10n.agentThinking,
              style: TextStyle(
                color: tertiary,
                fontStyle: FontStyle.italic,
                fontSize: 12.5,
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.text,
              style: TextStyle(color: tertiary, fontSize: 13, height: 1.4),
            ),
          ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.maxWidth});

  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: DroverColors.of(context).userBubble,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: SelectableText(
            text,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

// Chat-scale heading sizes (the gpt_markdown defaults are display-sized) with
// the auto h1 divider disabled. One instance per brightness, each built once
// from constants — the factory is costly (it builds a full ThemeData +
// Typography) — and picked by the active theme's brightness so assistant
// Markdown follows light/dark like the rest of the Drover-drawn UI. Heading
// colours use the theme's onSurface tone.
GptMarkdownThemeData _buildAssistantMarkdownTheme(
  Brightness brightness,
  Color heading,
) => GptMarkdownThemeData(
  brightness: brightness,
  h1: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: heading),
  h2: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: heading),
  h3: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: heading),
  h4: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: heading),
  h5: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: heading),
  h6: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: heading),
  autoAddDividerLineAfterH1: false,
);

// onSurface tones from the two Drover themes (see app_theme.dart), hardcoded
// here so the heading colour is a compile-time constant per cached instance.
final _assistantMarkdownThemeDark = _buildAssistantMarkdownTheme(
  Brightness.dark,
  const Color(0xFFF0E9DF),
);
final _assistantMarkdownThemeLight = _buildAssistantMarkdownTheme(
  Brightness.light,
  const Color(0xFF33291E),
);

class _AssistantMessage extends StatefulWidget {
  const _AssistantMessage({required this.text});

  final String text;

  @override
  State<_AssistantMessage> createState() => _AssistantMessageState();
}

class _AssistantMessageState extends State<_AssistantMessage> {
  // Cached rendered Markdown, rebuilt only when the text or the active
  // brightness changes (so the 2s poll's rebuilds are cheap while a system
  // light/dark switch still re-themes the content).
  Widget? _markdown;
  Brightness? _brightness;
  String? _builtText;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    if (_markdown == null ||
        _brightness != brightness ||
        _builtText != widget.text) {
      _brightness = brightness;
      _builtText = widget.text;
      _markdown = _buildMarkdown(context, widget.text);
    }
    return _markdown!;
  }

  Widget _buildMarkdown(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    final theme = scheme.brightness == Brightness.dark
        ? _assistantMarkdownThemeDark
        : _assistantMarkdownThemeLight;
    return SelectionArea(
      child: GptMarkdownTheme(
        gptThemeData: theme,
        child: GptMarkdown(
          text,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 13.5,
            height: 1.6,
          ),
          // Transcript text is untrusted remote content. gpt_markdown's default
          // image renderer would GET the URL via NetworkImage on build, so images
          // are shown as an inert, non-tappable placeholder — no network I/O.
          imageBuilder: (context, imageUrl, width, height) => Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: colors.toolSurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 16, color: scheme.onSurface),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    imageUrl,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Inline code: a small tonal panel keeps it readable on the surface.
          highlightBuilder: (context, code, style) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: colors.toolSurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              code,
              style: style.copyWith(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: scheme.onSurface,
              ),
            ),
          ),
          // Fenced code: syntax-highlighted when the fence tag names a known
          // language, otherwise a plain dark panel. Fenced blocks keep a fixed
          // dark surface in both themes (terminal-ish content), and scroll
          // horizontally so long lines never overflow the transcript width.
          codeBuilder: (context, name, code, closed) =>
              _FencedCode(language: name.trim(), code: code),
        ),
      ),
    );
  }
}

/// A flat, isolate-transferable highlighted run: its text plus the theme
/// attributes that differ from [_codeTextStyle]. A null [color] inherits the
/// base colour. TextSpan itself isn't sent across the isolate boundary — this
/// serialisable form is, and the UI side rebuilds spans from it.
class _CodeSegment {
  const _CodeSegment({
    required this.text,
    this.color,
    this.bold = false,
    this.italic = false,
  });

  final String text;
  final Color? color;
  final bool bold;
  final bool italic;
}

/// Highlights [code] as [language] and flattens the result to [_CodeSegment]s.
/// Runs on a background isolate via [compute]: highlight() can take seconds on
/// pathological input, so it must never touch the UI isolate. The size cap and
/// unknown-language check are done by the caller before spawning this.
List<_CodeSegment>? _highlightSegments((String, String) request) {
  final (language, code) = request;
  final highlighter = Highlight()..registerLanguages(builtinLanguages);
  final result = highlighter.highlight(code: code, language: language);
  // re_highlight runs in safe mode and can swallow a fatal parse error, leaving
  // errorRaised set and a truncated result; render such blocks plain instead.
  if (result.errorRaised != null) return null;
  // The panel already paints _codeSurface and the base style governs root text,
  // so the theme's root entry (a null-scope node the renderer never applies) is
  // irrelevant; pass a null base and carry only per-scope attributes.
  final renderer = TextSpanRenderer(null, githubDarkDimmedTheme);
  result.render(renderer);
  final span = renderer.span;
  if (span == null) return null;
  final segments = <_CodeSegment>[];
  void walk(InlineSpan node, TextStyle inherited) {
    if (node is! TextSpan) return;
    final merged = inherited.merge(node.style);
    final text = node.text;
    if (text != null && text.isNotEmpty) {
      segments.add(
        _CodeSegment(
          text: text,
          color: merged.color,
          bold: merged.fontWeight == FontWeight.bold,
          italic: merged.fontStyle == FontStyle.italic,
        ),
      );
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, merged);
    }
  }

  walk(span, const TextStyle());
  return segments;
}

/// A fenced code block, syntax-highlighted with re_highlight when [language] is
/// a known highlight.js language (or alias). Unknown/empty tags fall back to
/// plain monospace with no highlighting (no auto-detection).
class _FencedCode extends StatefulWidget {
  const _FencedCode({required this.language, required this.code});

  final String language;
  final String code;

  @override
  State<_FencedCode> createState() => _FencedCodeState();
}

class _FencedCodeState extends State<_FencedCode> {
  // Highlighted runs, or null to render plain (pending, unknown tag, too large,
  // or a highlight error). Cached so the 2s poll's rebuilds don't re-highlight;
  // recomputed only when the language or code actually change.
  List<_CodeSegment>? _segments;
  // Guards against a stale isolate result overwriting a newer request.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _highlight();
  }

  @override
  void didUpdateWidget(_FencedCode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language ||
        oldWidget.code != widget.code) {
      _segments = null; // show the plain fallback until the new result lands
      _highlight();
    }
  }

  Future<void> _highlight() async {
    // Invalidate any in-flight result before the pre-checks: when content at
    // this tree position changes to something non-highlightable, a stale
    // isolate result must not land on it.
    final id = ++_requestId;
    // Cheap synchronous pre-checks keep unknown/oversized blocks off the isolate.
    if (widget.language.isEmpty ||
        widget.code.length > _maxHighlightChars ||
        _codeHighlighter.getLanguage(widget.language) == null) {
      return;
    }
    List<_CodeSegment>? segments;
    try {
      segments = await compute(_highlightSegments, (
        widget.language,
        widget.code,
      ));
    } catch (_) {
      // Highlighting untrusted text must never surface as an error.
      segments = null;
    }
    // Apply only the latest request, and only while still mounted.
    if (!mounted || id != _requestId) return;
    setState(() => _segments = segments);
  }

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _codeSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: segments == null
            ? Text(widget.code, style: _codeTextStyle)
            : Text.rich(
                TextSpan(
                  style: _codeTextStyle,
                  children: [
                    for (final segment in segments)
                      TextSpan(
                        text: segment.text,
                        style: TextStyle(
                          color: segment.color,
                          fontWeight: segment.bold ? FontWeight.bold : null,
                          fontStyle: segment.italic ? FontStyle.italic : null,
                        ),
                      ),
                  ],
                ),
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

  Widget _optionButton(BuildContext context, PromptOption option) {
    final scheme = Theme.of(context).colorScheme;
    void press() => onSend(() => client.prompt(paneId, '${option.number}'));
    // The parsed TUI text is shown as-is; only the leading `N. ` numbering is
    // dropped from the label (the number is still what gets sent).
    final label = Text(
      option.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (option.selected) {
      return FilledButton(
        onPressed: press,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        child: label,
      );
    }
    return FilledButton.tonal(
      onPressed: press,
      style: FilledButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      child: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? scheme.surfaceContainerHigh : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x0F786446),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (question.question != null) ...[
            Text(
              question.question!,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in question.options)
                _optionButton(context, option),
            ],
          ),
        ],
      ),
    );
  }
}

Color _modeColor(AgentMode mode) {
  switch (mode) {
    case AgentMode.normal:
      return statusUnknown;
    case AgentMode.acceptEdit:
      return modeAcceptEdit;
    case AgentMode.plan:
      return modePlan;
    case AgentMode.auto:
      return modeAuto;
    case AgentMode.bypass:
      return modeBypass;
  }
}

String _modeLabel(AgentMode mode, AppLocalizations l10n) {
  switch (mode) {
    case AgentMode.normal:
      return l10n.agentModeNormal;
    case AgentMode.acceptEdit:
      return l10n.agentModeAcceptEdit;
    case AgentMode.plan:
      return l10n.agentModePlan;
    case AgentMode.auto:
      return l10n.agentModeAuto;
    case AgentMode.bypass:
      return l10n.agentModeBypass;
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
    required this.canAttachImages,
    required this.onRemoveImage,
    required this.onDictation,
    required this.onAttach,
    required this.onSend,
    required this.mode,
    required this.modeCapability,
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

  /// Whether the resolved agent has an [ImageAttachmentCapability]. The
  /// attach-image affordance is hidden entirely when it doesn't, rather than
  /// offering an attach flow that has nowhere to send its upload.
  final bool canAttachImages;
  final void Function(int index) onRemoveImage;
  final VoidCallback onDictation;
  final void Function(ImageAttachSource source) onAttach;
  final VoidCallback onSend;
  final AgentMode? mode;

  /// The resolved agent's mode capability, used only to cycle the mode when
  /// the chip is tapped. Non-null whenever [mode] is (both come from the
  /// same resolved capability), so the mode button is only ever built when
  /// this is available.
  final AgentModeCapability? modeCapability;

  /// Wraps client actions (mode cycling, Enter, Esc) so the caller can track
  /// in-flight sends.
  ///
  /// The mode chip is tappable: tapping it cycles the agent's mode via
  /// [modeCapability]. This can only cycle through modes, not jump to a
  /// specific one.
  final Future<bool> Function(Future<void> Function()) onAction;
  final HerdrClient client;
  final String paneId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final mode = this.mode;
    final isDark = scheme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: isDark
              ? null
              : const [
                  BoxShadow(
                    color: Color(0x0F786446),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
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
              contextMenuBuilder: noScanTextContextMenuBuilder,
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
                if (canAttachImages) ...[
                  _AttachButton(
                    sending: sending || dictationStarting || dictating,
                    onPick: onAttach,
                  ),
                  const SizedBox(width: 8),
                ],
                if (mode != null) ...[
                  _ModeButton(
                    mode: mode,
                    sending: sending,
                    onPressed: () => onAction(
                      () => modeCapability!.cycleMode(client, paneId),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                _EscapeButton(
                  sending: sending,
                  onPressed: () =>
                      onAction(() => client.sendKeys(paneId, 'esc')),
                ),
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
      width: 40,
      height: 40,
      child: Tooltip(
        message: l10n.agentAttachImage,
        child: OutlinedButton(
          key: const ValueKey('attach_image_button'),
          onPressed: sending ? null : () => _handleTap(context),
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
          child: const Icon(Icons.add, size: 20),
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
    final scheme = Theme.of(context).colorScheme;
    // Muted pill; the foreground carries the mode's meaning for non-normal
    // modes, and reads as a quiet default (onSurfaceVariant) for normal.
    final fg = mode == AgentMode.normal
        ? scheme.onSurfaceVariant
        : _modeColor(mode);
    return SizedBox(
      height: 40,
      child: Tooltip(
        message: l10n.agentCycleModeTooltip,
        child: OutlinedButton(
          key: const ValueKey('cycle_mode_button'),
          onPressed: sending ? null : onPressed,
          style: OutlinedButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 13),
            backgroundColor: DroverColors.of(context).idlePillBg,
            foregroundColor: fg,
            side: BorderSide.none,
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tune, size: 16),
              const SizedBox(width: 5),
              Text(_modeLabel(mode, l10n)),
            ],
          ),
        ),
      ),
    );
  }
}

/// An always-available escape hatch that sends a raw Esc key to the agent.
/// Unlike the send/stop button (which only offers Esc while the agent is
/// working), this stays enabled whatever the agent's status, so the user can
/// dismiss a full-screen interactive TUI (e.g. a `/usage` slash-command
/// screen) even when the agent is idle or blocked. Disabled only while a send
/// is in flight ([sending]).
class _EscapeButton extends StatelessWidget {
  const _EscapeButton({required this.sending, required this.onPressed});

  final bool sending;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: 40,
      height: 40,
      child: Tooltip(
        message: l10n.agentSendEscape,
        child: OutlinedButton(
          key: const ValueKey('send_escape_button'),
          onPressed: sending ? null : onPressed,
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
          child: const Text(
            'Esc',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
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
      width: 40,
      height: 40,
      child: Tooltip(
        message: dictating ? l10n.agentStopDictation : l10n.agentDictateMessage,
        child: OutlinedButton(
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
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
      width: 40,
      height: 40,
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

/// The 案D bottom switcher bar: a fixed 一覧 (Herd) tab followed by every
/// running agent, so the user can see each agent's status and switch between
/// them without leaving the conversation. Visible only when 2+ agents are
/// running; with 0/1 it slides out and collapses to just the home-indicator
/// inset, and slides back in (translateY + fade, ~240ms ease-out) when a
/// second agent appears.
class _AgentSwitcherBar extends StatefulWidget {
  const _AgentSwitcherBar({
    required this.agents,
    required this.currentPaneId,
    required this.onSelect,
    required this.onOpenHerd,
  });

  final List<AgentInfo> agents;
  final String currentPaneId;
  final void Function(AgentInfo agent) onSelect;
  final VoidCallback onOpenHerd;

  @override
  State<_AgentSwitcherBar> createState() => _AgentSwitcherBarState();
}

class _AgentSwitcherBarState extends State<_AgentSwitcherBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;

  bool get _visible => widget.agents.length >= 2;

  static String _displayName(AgentInfo agent) =>
      agent.sessionTitle ?? agent.name ?? agent.agent ?? agent.paneId;

  /// The bar label: the session title (or fallback) shortened to 6 code points
  /// + '…' once it exceeds 7 (the spec's rule), rune-safe for multibyte text.
  static String _shortLabel(String text) {
    final runes = text.runes.toList();
    if (runes.length <= 7) return text;
    return '${String.fromCharCodes(runes.take(6))}…';
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: _visible ? 1 : 0,
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  }

  @override
  void didUpdateWidget(_AgentSwitcherBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Slide in on 1→2, slide out on 2→1; both no-op when already settled.
    if (_visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, _) {
        final t = _curve.value.clamp(0.0, 1.0);
        // Settled hidden: the bar is gone entirely (no children in the tree),
        // leaving only the home-indicator inset so the composer keeps its
        // clearance.
        if (t == 0 && !_visible) {
          return SizedBox(width: double.infinity, height: bottomInset);
        }
        // The bar body's reserved height animates via the heightFactor while
        // its content translates up from below and fades in; a shrinking
        // spacer keeps the total bottom clearance ≈ the inset throughout the
        // transition (the body carries the inset itself once fully in).
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: t,
                child: Opacity(
                  opacity: t,
                  child: FractionalTranslation(
                    translation: Offset(0, 1 - t),
                    child: _bar(context, bottomInset),
                  ),
                ),
              ),
            ),
            SizedBox(height: (1 - t) * bottomInset),
          ],
        );
      },
    );
  }

  Widget _bar(BuildContext context, double bottomInset) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(14, 9, 14, 9 + bottomInset),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _herdTab(context),
            for (final agent in widget.agents) ...[
              const SizedBox(width: 14),
              _agentItem(context, agent),
            ],
          ],
        ),
      ),
    );
  }

  Widget _herdTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    return _BarCell(
      key: const ValueKey('switcher_herd_tab'),
      onTap: widget.onOpenHerd,
      box: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outline, width: 1.5),
        ),
        child: Icon(Icons.grid_view, size: 20, color: scheme.onSurfaceVariant),
      ),
      label: l10n.agentSwitcherHerdTab,
      labelColor: colors.tertiaryText,
    );
  }

  Widget _agentItem(BuildContext context, AgentInfo agent) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    final isCurrent = agent.paneId == widget.currentPaneId;
    return _BarCell(
      key: ValueKey('switcher_agent_${agent.paneId}'),
      onTap: isCurrent ? null : () => widget.onSelect(agent),
      box: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              // The ring paints over the avatar's edge, so current/other keep
              // the same 44px footprint (only the border colour differs).
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isCurrent ? scheme.primary : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: AgentAvatar(agent: agent.agent, size: 44, radius: 16),
            ),
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: colors.statusDot(agent.status),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.surfaceContainerLow,
                    width: 2.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      label: _shortLabel(_displayName(agent)),
      labelColor: isCurrent ? scheme.primary : colors.tertiaryText,
    );
  }
}

/// One switcher-bar entry: a 44×44 box (avatar or the 一覧 tile) above a 9px
/// label, tappable as a unit.
class _BarCell extends StatelessWidget {
  const _BarCell({
    super.key,
    required this.box,
    required this.label,
    required this.labelColor,
    required this.onTap,
  });

  final Widget box;
  final String label;
  final Color labelColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          box,
          const SizedBox(height: 4),
          SizedBox(
            width: 52,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: labelColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
