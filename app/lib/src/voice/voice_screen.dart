import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../models/agent_preset.dart';
import '../utils/path.dart';
import 'voice_drafts.dart';
import 'voice_herd.dart';
import 'voice_session.dart';

/// The voice-assistant stage: an orb that follows the voice, over a status
/// line and a live caption, pending draft cards, and round controls along
/// the bottom. The transcript log sits behind a toggle. Owns the [session]
/// lifecycle: starts it on first frame, disposes it with the screen.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.session});

  final VoiceSession session;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _scroll = ScrollController();
  var _showTranscript = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.session.start());
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    widget.session.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _wasAtBottom {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    return position.pixels >= position.maxScrollExtent - 40;
  }

  void _onSessionChanged() {
    if (!mounted) return;
    // Follow new entries only if the user hasn't scrolled up to read.
    final stick = _wasAtBottom;
    setState(() {});
    if (!stick) return;
    _jumpToEnd();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _toggleTranscript() {
    setState(() => _showTranscript = !_showTranscript);
    // Opened to catch up, so land on the newest line.
    if (_showTranscript) _jumpToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = widget.session;
    final active =
        session.status == VoiceSessionStatus.connecting ||
        session.status == VoiceSessionStatus.live;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No AppBar, so this is the only labelled way back while live
            // (macOS, VoiceOver); leaving disposes the session as before.
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(padding: EdgeInsets.all(8), child: BackButton()),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _showTranscript
                    ? KeyedSubtree(
                        key: const ValueKey('transcript'),
                        child: _transcript(context, l10n),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('stage'),
                        child: _stage(context, l10n),
                      ),
              ),
            ),
            _controls(context, l10n, active),
          ],
        ),
      ),
    );
  }

  Widget _stage(BuildContext context, AppLocalizations l10n) {
    final session = widget.session;
    final tertiary = DroverColors.of(context).tertiaryText;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // Takes what the cards leave; scrolls once that is less than
            // the orb, status and caption need.
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Orb(
                      status: session.status,
                      level: session.level,
                      listening: session.partialUser != null,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _statusLabel(l10n, session),
                      key: const ValueKey('voice_status'),
                      textAlign: TextAlign.center,
                      style: droverLabelStyle(context, color: tertiary),
                    ),
                    const SizedBox(height: 10),
                    DefaultTextStyle.merge(
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      child: Column(children: _caption(context, l10n)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The cards are the actionable part, so they win over the orb: as
          // tall as they need up to most of the stage, then they scroll. Not
          // a Flexible — a loose flex child never hands its unused share
          // back to the Expanded above, which would leave a gap under one
          // short card.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.7),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final draft in session.drafts.pending)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: _draftCard(context, l10n, draft.id, stretch: true),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What sits under the status label: the live transcription while someone
  /// is speaking; otherwise the trailing system notices (why the session
  /// ended, that it resumed); otherwise the greeting on a fresh live session.
  /// While live, notices about the previous session's end stay off the
  /// stage — after Restart the caption must not read "Session ended".
  List<Widget> _caption(BuildContext context, AppLocalizations l10n) {
    final session = widget.session;
    final scheme = Theme.of(context).colorScheme;
    final body = TextStyle(color: scheme.onSurface, fontSize: 17, height: 1.4);
    final muted = TextStyle(
      color: DroverColors.of(context).tertiaryText,
      fontSize: 13,
      height: 1.4,
    );
    if (session.partialAssistant case final text?) {
      return [Text(text, style: body)];
    }
    if (session.partialUser case final text?) {
      return [Text(text, style: body.copyWith(color: scheme.onSurfaceVariant))];
    }
    final notices = session.entries.reversed
        .takeWhile((e) => e.kind == VoiceEntryKind.system)
        .toList()
        .reversed
        .toList();
    const previousSession = {
      VoiceSession.endedCode,
      VoiceSession.capReachedCode,
      VoiceSession.unsentDraftsCode,
    };
    final stale =
        session.status == VoiceSessionStatus.live &&
        notices.isNotEmpty &&
        previousSession.contains(notices.last.text);
    if (notices.isNotEmpty && !stale) {
      return [
        for (final entry in notices)
          Text(_systemLabel(l10n, entry.text), style: muted),
      ];
    }
    if (session.status == VoiceSessionStatus.live && session.entries.isEmpty) {
      return [
        Text(l10n.voiceGreeting, style: body),
        const SizedBox(height: 8),
        Text(l10n.voiceHint, style: muted),
      ];
    }
    // Between turns the last thing said stays up, so an answer can still be
    // glanced at once the model has stopped speaking.
    final spoken = session.entries.lastWhere(
      (e) =>
          e.kind == VoiceEntryKind.user || e.kind == VoiceEntryKind.assistant,
      orElse: () => const VoiceEntry(VoiceEntryKind.system, ''),
    );
    return switch (spoken.kind) {
      VoiceEntryKind.assistant => [
        Text(spoken.text, style: body.copyWith(color: scheme.onSurfaceVariant)),
      ],
      VoiceEntryKind.user => [
        Text(spoken.text, style: muted.copyWith(fontSize: 15)),
      ],
      _ => const [],
    };
  }

  Widget _transcript(BuildContext context, AppLocalizations l10n) {
    final session = widget.session;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        for (final entry in session.entries) _entryRow(context, l10n, entry),
        if (session.partialUser case final text?)
          _entryRow(context, l10n, VoiceEntry(VoiceEntryKind.user, text)),
        if (session.partialAssistant case final text?)
          _entryRow(context, l10n, VoiceEntry(VoiceEntryKind.assistant, text)),
      ],
    );
  }

  /// Transcript toggle on the left, Restart in the middle once the session
  /// is over, and the ink-filled End/Close on the right. Exactly one button
  /// carries `voice_action_button`: End while active, Restart after.
  Widget _controls(BuildContext context, AppLocalizations l10n, bool active) {
    final session = widget.session;
    final tertiary = DroverColors.of(context).tertiaryText;
    final tonal = IconButton.styleFrom(fixedSize: const Size.square(52));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Center(
              child: IconButton.filledTonal(
                key: const ValueKey('voice_transcript_button'),
                style: tonal,
                isSelected: _showTranscript,
                icon: const Icon(Icons.notes),
                selectedIcon: const Icon(Icons.graphic_eq),
                tooltip: l10n.voiceTranscript,
                onPressed: _toggleTranscript,
              ),
            ),
          ),
          Expanded(
            child: active
                ? const SizedBox.shrink()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.filledTonal(
                        key: const ValueKey('voice_action_button'),
                        style: tonal,
                        icon: const Icon(Icons.refresh),
                        tooltip: l10n.voiceRestart,
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          session.start();
                        },
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.voiceRestart,
                        style: droverLabelStyle(context, color: tertiary),
                      ),
                    ],
                  ),
          ),
          Expanded(
            child: Center(
              // Colours are the M3 defaults: both themes pin primary/onPrimary
              // to the page's ink and surface, the same pair FilledButton uses.
              child: IconButton.filled(
                key: ValueKey(
                  active ? 'voice_action_button' : 'voice_close_button',
                ),
                style: IconButton.styleFrom(fixedSize: const Size.square(56)),
                icon: const Icon(Icons.close),
                tooltip: active ? l10n.voiceEnd : l10n.voiceClose,
                onPressed: active
                    ? () {
                        HapticFeedback.lightImpact();
                        session.stop();
                      }
                    : () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(AppLocalizations l10n, VoiceSession session) =>
      switch (session.status) {
        VoiceSessionStatus.idle ||
        VoiceSessionStatus.connecting => l10n.voiceStatusConnecting,
        VoiceSessionStatus.live =>
          session.speaking ? l10n.voiceStatusSpeaking : l10n.voiceStatusLive,
        VoiceSessionStatus.ended => l10n.voiceStatusEnded,
        VoiceSessionStatus.error => l10n.voiceStatusError(
          session.error == VoiceSession.micPermissionDenied
              ? l10n.voiceMicPermissionDenied
              : session.error ?? '',
        ),
      };

  /// Copy for a [VoiceEntryKind.system] code; unknown codes pass through.
  String _systemLabel(AppLocalizations l10n, String code) => switch (code) {
    VoiceSession.interruptedCode => l10n.voiceInterrupted,
    VoiceSession.goingAwayCode => l10n.voiceGoingAway,
    VoiceSession.resumedCode => l10n.voiceResumed,
    VoiceSession.endedCode => l10n.voiceEnded,
    VoiceSession.announceFailedCode => l10n.voiceEventAnnounceFailed,
    VoiceSession.unsentDraftsCode => l10n.voiceUnsentDrafts,
    VoiceSession.sendFailedCode => l10n.voiceSendFailed,
    VoiceSession.launchFailedCode => l10n.voiceLaunchFailed,
    VoiceSession.capReachedCode => l10n.voiceCapReached,
    _ => code,
  };

  Widget _entryRow(
    BuildContext context,
    AppLocalizations l10n,
    VoiceEntry entry,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    final muted = TextStyle(color: colors.tertiaryText, fontSize: 12.5);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: switch (entry.kind) {
        VoiceEntryKind.user => _bubble(
          entry.text,
          alignment: Alignment.centerRight,
          color: colors.userBubble,
          textColor: scheme.onSurface,
          maxWidth: maxWidth,
        ),
        VoiceEntryKind.assistant => _bubble(
          entry.text,
          alignment: Alignment.centerLeft,
          color: scheme.surfaceContainer,
          textColor: scheme.onSurface,
          maxWidth: maxWidth,
        ),
        VoiceEntryKind.tool => Row(
          children: [
            Icon(Icons.build, size: 14, color: colors.tertiaryText),
            const SizedBox(width: 6),
            Text(l10n.voiceToolCalled(entry.text), style: muted),
          ],
        ),
        VoiceEntryKind.system => Text(
          _systemLabel(l10n, entry.text),
          textAlign: TextAlign.center,
          style: muted,
        ),
        VoiceEntryKind.draft => _draftCard(context, l10n, entry.text),
        VoiceEntryKind.sent => Text(
          switch (widget.session.drafts.byId(entry.text)!) {
            MessageDraft(:final agent) => l10n.voiceDraftSent(
              voiceAgentTitle(agent),
            ),
            LaunchDraft(:final kind, :final cwd) => l10n.voiceLaunchStarted(
              _kindLabel(kind),
              lastPathSegment(cwd),
            ),
          },
          textAlign: TextAlign.center,
          style: muted,
        ),
        VoiceEntryKind.event => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.notifications_none,
              size: 14,
              color: colors.tertiaryText,
            ),
            const SizedBox(width: 6),
            Flexible(child: Text(_eventLabel(l10n, entry.text), style: muted)),
          ],
        ),
      },
    );
  }

  /// The draft [id] as a card: a header, the full text, and an action
  /// button while it is still pending — Send for a message, Launch for a new
  /// agent. Once acted on the button goes and the header shows a check; the
  /// "sent" statement itself is the [VoiceEntryKind.sent] line, so it appears
  /// exactly once. In the transcript it sits like an assistant bubble; on the
  /// stage ([stretch]) it spans the width like a sheet.
  Widget _draftCard(
    BuildContext context,
    AppLocalizations l10n,
    String id, {
    bool stretch = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    final drafts = widget.session.drafts;
    final draft = drafts.byId(id)!;
    final pending = drafts.isPending(draft);
    final (
      String header,
      String body,
      String action,
      VoidCallback onAction,
    ) = switch (draft) {
      MessageDraft(:final agent, :final message) => (
        pending
            ? l10n.voiceDraftPending(voiceAgentTitle(agent))
            : voiceAgentTitle(agent),
        message,
        l10n.voiceDraftSend,
        () => widget.session.sendDraft(id),
      ),
      LaunchDraft(:final kind, :final cwd, :final brief) => (
        pending
            ? l10n.voiceLaunchPending(_kindLabel(kind), lastPathSegment(cwd))
            : l10n.voiceLaunchHeader(_kindLabel(kind), lastPathSegment(cwd)),
        brief,
        l10n.voiceLaunchStart,
        () => widget.session.launchDraft(id),
      ),
    };
    final card = Container(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(droverRadiusMedium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pending
                    ? (draft is LaunchDraft
                          ? Icons.rocket_launch
                          : Icons.schedule_send)
                    : Icons.check,
                size: 14,
                color: colors.tertiaryText,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  header,
                  style: droverLabelStyle(context, color: colors.tertiaryText),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
          if (pending) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: ValueKey(
                  draft is LaunchDraft
                      ? 'voice_launch_$id'
                      : 'voice_draft_send_$id',
                ),
                onPressed: drafts.isBusy(draft) ? null : onAction,
                child: Text(action),
              ),
            ),
          ],
        ],
      ),
    );
    if (stretch) return card;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: card,
      ),
    );
  }

  /// The preset label for an agent [kind] (e.g. "Claude Code"), or the kind
  /// itself when no preset matches.
  String _kindLabel(String kind) =>
      kAgentPresets.where((p) => p.kind == kind).firstOrNull?.label ?? kind;

  /// Maps an event code (`finished:<title>` / `blocked:<title>`) to copy.
  String _eventLabel(AppLocalizations l10n, String code) {
    final split = code.indexOf(':');
    final kind = split < 0 ? code : code.substring(0, split);
    final name = split < 0 ? '' : code.substring(split + 1);
    return kind == 'blocked'
        ? l10n.voiceEventBlocked(name)
        : l10n.voiceEventFinished(name);
  }

  Widget _bubble(
    String text, {
    required Alignment alignment,
    required Color color,
    required Color textColor,
    required double maxWidth,
  }) => Align(
    alignment: alignment,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(droverRadiusMedium),
        ),
        child: Text(
          text,
          style: TextStyle(color: textColor, fontSize: 13.5, height: 1.5),
        ),
      ),
    ),
  );
}

/// The stage's centre: a soft glow of the page's ink, no hue. Dim while
/// connecting and once the session is over; lit while live, and gains a thin
/// ring while the user is being heard ([listening]). Its size follows
/// [level] — the voice actually in the room — so it is completely still when
/// nothing is being said, and fixed when the platform asks for no animation.
class _Orb extends StatelessWidget {
  const _Orb({
    required this.status,
    required this.level,
    required this.listening,
  });

  final VoiceSessionStatus status;

  /// The session's smoothed 0..1 audio level. Already smoothed upstream, so
  /// it drives the scale directly — no second easing layer here.
  final ValueListenable<double> level;

  final bool listening;

  static const _size = 168.0;

  /// ponytail: [_scaleMin] and [_scaleMax] are a by-eye knob, not derived —
  /// the union of the old idle/speaking tweens, to be tuned on a device.
  static const _scaleMin = 0.96;
  static const _scaleMax = 1.08;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    // Reduce motion reads as a permanently silent room: fixed at rest size.
    final still = MediaQuery.disableAnimationsOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: level,
      builder: (context, value, child) => Transform.scale(
        key: const ValueKey('voice_orb_scale'),
        scale: _scaleMin + (_scaleMax - _scaleMin) * (still ? 0 : value),
        child: child,
      ),
      child: AnimatedOpacity(
        opacity: status == VoiceSessionStatus.live ? 1 : 0.45,
        duration: const Duration(milliseconds: 400),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: ink.withValues(alpha: listening ? 0.35 : 0),
              width: 1.5,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                // A body with a soft rim rather than a fog: opaque well past
                // the centre, then a short fall-off.
                colors: [
                  ink.withValues(alpha: 0.92),
                  ink.withValues(alpha: 0.85),
                  ink.withValues(alpha: 0),
                ],
                stops: const [0, 0.62, 1],
              ),
            ),
            child: const SizedBox.square(dimension: _size),
          ),
        ),
      ),
    );
  }
}
