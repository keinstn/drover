import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../models/agent_info.dart';
import '../models/agent_preset.dart';
import '../utils/path.dart';
import '../widgets/agent_switcher_bar.dart';
import 'voice_drafts.dart';
import 'voice_herd.dart';
import 'voice_session.dart';

/// Secondary text on this screen, lifted off [DroverColors.tertiaryText].
/// The edge glow lays up to ~0.41 of its ink over the ground behind every
/// unbubbled line — in the bottom corners, where the 0.31 wash along the
/// bottom edge and the 0.14 side glow meet — which leaves both themes'
/// tertiary ink (`#908F96` / `#86868B`) far under the 4.5:1 WCAG AA wants
/// for text this size. These clear that worst case (the contrast test reads
/// the ground off the render, per theme and per speaker) with margin.
///
/// Dark is a lift off `#CFCED5`, which the stronger glow no longer clears;
/// light is a *darkening* of the theme's tertiary ink, because on the white
/// page the glow subtracts luminance instead of adding it.
const _mutedInkDark = Color(0xFFDBDAE1);
const _mutedInkLight = Color(0xFF4F4F55);

Color _mutedInk(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? _mutedInkDark
    : _mutedInkLight;

/// The unbubbled lines — tool, system, sent, event and the error — in that
/// ink.
TextStyle _mutedStyle(BuildContext context) =>
    TextStyle(color: _mutedInk(context), fontSize: 12.5);

/// Who holds the floor, as light: the cool ink whenever the assistant is
/// listening — which includes a silent room, because waiting *is* the user's
/// turn — and the warm one while the assistant talks. Colour on a drover
/// screen means *which agent* or *what state* and never decoration (see the
/// doc on [droverDarkTheme]); who holds the floor is a state of the voice
/// session, so this is inside that rule.
///
/// These are the only inks the glow is ever painted in: no `onSurface`
/// reaches it on either theme, so the light theme's white page never takes
/// the grey haze that used to keep this screen dark.
///
/// Screen-local and not a [ThemeExtension]: nothing outside this screen has
/// a use for them.
///
/// ponytail: all four are a by-eye knob, to be tuned on a device against the
/// reference. Within a pair they share an HSL saturation and lightness and
/// differ only in hue — 210° and 16° — so a tint reads as the same light
/// taking on a colour, never as a dimmer or brighter one; the tests check
/// the assistant's glow is never dimmer than the resting one.
///
/// Dark: S 79%, L 75.5% — a pale light on a near-black page, which *adds*
/// luminance. Light: S 70%, L 54% — the same two hues, dark and saturated
/// enough that on white they subtract luminance as *chroma* (the page gains
/// a colour) rather than as grey. Their relative luminances match to within
/// 1% (0.242 / 0.244), so neither speaker's light is the brighter one.
const _listeningInkDark = Color(0xFF8FC0F2);
const _speakingInkDark = Color(0xFFF2A98F);
const _listeningInkLight = Color(0xFF388ADC);
const _speakingInkLight = Color(0xFFDC6338);

/// The listening ink for [context]'s theme. Public because a call now stays
/// live while the user is elsewhere in drover, and the herd screen's voice
/// button wears this same ink to say so — one "we are listening" colour, not
/// two that drift apart.
Color voiceListeningInk(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? _listeningInkDark
    : _listeningInkLight;

/// The voice-assistant screen: the transcript *is* the screen — every line in
/// one log, pending draft cards pinned above the controls until they are
/// acted on — with the assistant's presence as light bleeding in from the
/// bottom edge, and round controls along the bottom.
/// Drives the [session] but does not own it: it leaves it running when the
/// screen goes — the call outlives this route, so the conversation, and the
/// disposing, belong to whoever built it.
/// A *new* call waits for the Start button: minting its token spends a voice
/// credit, so arriving here must not be the charge. Continuing a call that is
/// already going, or one parked by a backgrounding, costs nothing and so needs
/// no tap — that is what the post-frame [VoiceSession.start] below is for.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({
    super.key,
    required this.session,
    this.agents,
    this.onOpenAgent,
  });

  final VoiceSession session;

  /// The herd's agents, live: a poll landing a new list repaints the switcher
  /// bar's dots under the header. Null — together with [onOpenAgent] — means
  /// no bar at all, which is what a preview or a test that hands over neither
  /// gets.
  final ValueListenable<List<AgentInfo>>? agents;

  /// Opens [agent]'s screen on top of the call, which keeps running.
  final void Function(AgentInfo agent)? onOpenAgent;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> with WidgetsBindingObserver {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.session.resumable) widget.session.start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_onSessionChanged);
    // The session is left alone: not disposed, not ended, and the screen
    // wake not released. The call keeps listening while the user is on
    // another drover screen, and both the things that must not outlive the
    // foreground — the open mic and the held-off auto-lock — now belong to
    // the herd screen, which is still there when this one is gone.
    _scroll.dispose();
    super.dispose();
  }

  /// iOS silently kills the mic on backgrounding, so a live conversation must
  /// end explicitly rather than sit half-dead. Only `paused`: `inactive` also
  /// fires for a Control Centre glance, an app-switcher flick and an
  /// incoming-call banner, and ending a live conversation for those would be
  /// worse than the bug this fixes (same distinction as `main.dart`'s own
  /// `didChangeAppLifecycleState`).
  ///
  /// Coming back to the foreground continues the conversation, the same way
  /// re-entering the screen does — [initState]'s post-frame `start()` is the
  /// other half of the same rule. Both can fire for one return (a `resumed`
  /// landing on a freshly built screen) without opening a second
  /// conversation, because the session serialises them itself: a `start()`
  /// on a session that is still going returns having done nothing, and one
  /// that arrives while an end is still releasing the mic and the socket
  /// waits that end out before deciding.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.session.background();
    if (state == AppLifecycleState.resumed && widget.session.resumable) {
      widget.session.start();
    }
  }

  /// True while connecting or live, which is what [_scaffold] renders the
  /// screen as active for.
  bool get _isActive =>
      widget.session.status == VoiceSessionStatus.connecting ||
      widget.session.status == VoiceSessionStatus.live;

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

  /// The screen follows the ambient theme. It used to force the dark one:
  /// an *achromatic* glow can only depict light by adding luminance, and on a
  /// white page it subtracted it — measured on device it read as a smudge or
  /// a paper fold. The speaker tint changed that premise: a white page cannot
  /// gain luminance but it can gain chroma, so on light the glow is a pale
  /// cool or warm wash instead of a grey one. Nothing here annotates the
  /// status bar either: once this route is opaque the host's AppBar is no
  /// longer built, and with no annotation in the tree the status bar simply
  /// keeps the last style it was given — the host's, under the same theme.
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = widget.session;
    final active = _isActive;
    // `_fail` adds no entry, so on an error the log would otherwise be
    // empty and the only account of what went wrong would be the header
    // label — which clamps to two lines. So the error rides the log as its
    // last line, where it wraps as far as it needs to: as the whole of it
    // after a failed connect, at the end after a mid-session drop.
    final errorText = session.status == VoiceSessionStatus.error
        ? _statusLabel(l10n, session)
        : null;
    // Holds, not draws: a pending draft's row renders nothing, but a draft
    // always trails the tool entry that created it (`voice_session.dart`
    // adds one per call before running it), so entries are never all
    // invisible outside a test that pushes drafts straight into VoiceDrafts.
    // The error counts as content: the greeting invites the user to talk,
    // and there is nothing listening.
    final empty =
        session.entries.isEmpty &&
        session.partialUser == null &&
        session.partialAssistant == null &&
        errorText == null;
    return Scaffold(
      // The glow is the whole body's bottom edge, not the transcript's: put
      // it under the SafeArea so it bleeds past the controls into the very
      // edge of the screen, and out of the hit test so it can't eat a tap.
      body: Stack(
        children: [
          // RepaintBoundary: the glow repaints at audio rate, and without
          // one every frame re-records the header, log and controls too.
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: _EdgeGlow(
                  level: session.level,
                  speaking: session.speaking,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // No AppBar, so this is the only labelled way back
                    // while live (macOS, VoiceOver); leaving leaves the call
                    // running, which End is still there to finish for good.
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: BackButton(),
                    ),
                    // Expanded, end-aligned: the error status carries the
                    // error text, which is any length, so it takes every
                    // pixel the back button leaves rather than half of it.
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, right: 20),
                        child: Text(
                          _statusLabel(l10n, session),
                          key: const ValueKey('voice_status'),
                          textAlign: TextAlign.end,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          // The screen's muted ink, not the theme's tertiary:
                          // on the light page the latter is 3.6:1 at label
                          // size, and this screen was 5.6:1 before it
                          // followed the theme.
                          style: droverLabelStyle(
                            context,
                            color: _mutedInk(context),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // The roster under the header: who exists, what their status
                // dot says, and the names the user can say out loud. Outside
                // the Expanded below, so it shrinks the transcript region
                // rather than floating over it.
                if (widget.agents case final agents?)
                  if (widget.onOpenAgent case final onOpenAgent?)
                    ValueListenableBuilder<List<AgentInfo>>(
                      valueListenable: agents,
                      builder: (context, list, _) => AgentSwitcherBar(
                        agents: list,
                        // This screen is not one of the agents, so nothing in
                        // the bar is current — and one agent is still worth
                        // showing, unlike on an agent's own screen.
                        currentPaneId: null,
                        onSelect: onOpenAgent,
                        onOpenHerd: () => Navigator.of(
                          context,
                        ).popUntil((route) => route.isFirst),
                        anchor: AgentSwitcherBarAnchor.top,
                        minAgents: 1,
                      ),
                    ),
                // LayoutBuilder inside the Expanded, not around the
                // Column: a non-flex child of a Column is measured with an
                // unbounded main axis, so a cap taken out there would be
                // infinity. Here `constraints.maxHeight` is the
                // header-to-controls region, which is what gets split.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: empty
                              ? _empty(context, l10n)
                              : _transcript(context, l10n, errorText),
                        ),
                        _pending(context, l10n, constraints.maxHeight),
                      ],
                    ),
                  ),
                ),
                _controls(context, l10n, active),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Before anything has been said: the greeting and what to try, centred in
  /// the transcript's place. Goes as soon as the first line lands.
  // Scrolls once the region is shorter than the two paragraphs need — at an
  // accessibility text size the hint alone can outgrow a phone's height, and
  // the stage this replaced scrolled for the same reason.
  Widget _empty(BuildContext context, AppLocalizations l10n) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.voiceGreeting,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 17,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.voiceHint,
            textAlign: TextAlign.center,
            style: _mutedStyle(context).copyWith(fontSize: 13, height: 1.4),
          ),
        ],
      ),
    ),
  );

  /// Pending draft cards, pinned between the log and the controls. They are
  /// the actionable part — the manual Send is the ground truth when the model
  /// narrates having sent something it never sent — so they must not be
  /// scrollable away: the model talking on, or the user scrolling up to
  /// re-read, would otherwise carry the button off screen and the only notice
  /// left would be "unsent drafts" at the end of the session.
  ///
  /// Half of the region, not the old stage's 0.7: what gets squeezed now is
  /// the transcript, which is real content, so the log keeps the larger half
  /// while two cards still fit whole on a phone. `reverse`, so the cards sit
  /// on the controls and the newest card's button is the one on screen —
  /// scrolled from the top instead, a single over-long brief would push its
  /// own button out of the viewport. Order is unaffected: the scroll view has
  /// one child, so only where it starts changes.
  Widget _pending(BuildContext context, AppLocalizations l10n, double height) {
    final pending = widget.session.drafts.pending;
    if (pending.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height * 0.5),
      child: SingleChildScrollView(
        key: const ValueKey('voice_pending_drafts'),
        reverse: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final draft in pending)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _draftCard(context, l10n, draft.id),
              ),
          ],
        ),
      ),
    );
  }

  Widget _transcript(
    BuildContext context,
    AppLocalizations l10n,
    String? errorText,
  ) {
    final session = widget.session;
    // builder, not ListView(children:): the session notifies several times a
    // second during a turn, and the log grows across Restarts.
    final partials = [
      if (session.partialUser case final text?)
        VoiceEntry(VoiceEntryKind.user, text),
      if (session.partialAssistant case final text?)
        VoiceEntry(VoiceEntryKind.assistant, text),
    ];
    final entries = session.entries;
    final rows = entries.length + partials.length;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      itemCount: rows + (errorText == null ? 0 : 1),
      itemBuilder: (context, i) => i == rows
          // No maxLines: the header's copy of this is clamped to two, so
          // the rest of a long host error has to be readable somewhere.
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                errorText!,
                key: const ValueKey('voice_error_body'),
                textAlign: TextAlign.center,
                style: _mutedStyle(context),
              ),
            )
          : _entryRow(
              context,
              l10n,
              i < entries.length ? entries[i] : partials[i - entries.length],
            ),
    );
  }

  /// The middle slot before and after a call — Start on a screen that has
  /// never run, Restart once one is over — and the ink-filled End/Close on the
  /// right. Exactly one button carries `voice_action_button`: End while
  /// active, Restart after. Start stays off that key rather than becoming a
  /// third occupant of it: it is the one control that opens a call that was
  /// never opened, and a test reaching for End has to fail rather than find
  /// it under the same key.
  Widget _controls(BuildContext context, AppLocalizations l10n, bool active) {
    final session = widget.session;
    final tonal = IconButton.styleFrom(fixedSize: const Size.square(52));
    Widget starter(Key key, IconData icon, String label) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          key: key,
          style: tonal,
          icon: Icon(icon),
          tooltip: label,
          onPressed: () {
            HapticFeedback.lightImpact();
            session.start();
          },
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: droverLabelStyle(context, color: _mutedInk(context)),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Empty slot, so Restart stays centred and Close stays right.
          const Spacer(),
          Expanded(
            child: active
                ? const SizedBox.shrink()
                : session.status == VoiceSessionStatus.idle
                ? starter(
                    const ValueKey('voice_start_button'),
                    Icons.mic_none,
                    l10n.voiceStart,
                  )
                : starter(
                    const ValueKey('voice_action_button'),
                    Icons.refresh,
                    l10n.voiceRestart,
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
        // Only ever the value a session is built with, so it means "never
        // started" — the screen waiting for the Start tap, not a dial in
        // progress.
        VoiceSessionStatus.idle => l10n.voiceStatusReady,
        VoiceSessionStatus.connecting => l10n.voiceStatusConnecting,
        VoiceSessionStatus.live =>
          session.speaking ? l10n.voiceStatusSpeaking : l10n.voiceStatusLive,
        VoiceSessionStatus.ended => l10n.voiceStatusEnded,
        VoiceSessionStatus.error => l10n.voiceStatusError(
          switch (session.error) {
            VoiceSession.micPermissionDenied => l10n.voiceMicPermissionDenied,
            VoiceSession.outOfCredits => l10n.voiceOutOfCredits,
            final error => error ?? '',
          },
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
    VoiceSession.backgroundedCode => l10n.voiceBackgrounded,
    _ => code,
  };

  Widget _entryRow(
    BuildContext context,
    AppLocalizations l10n,
    VoiceEntry entry,
  ) {
    final drafts = widget.session.drafts;
    // While pending, the card lives pinned above the controls, so the log
    // skips it — one card, one place. Once resolved it takes its
    // chronological place here. Returns above the row's padding, so a
    // suppressed draft leaves no gap either.
    if (entry.kind == VoiceEntryKind.draft &&
        drafts.isPending(drafts.byId(entry.text)!)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
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
            Icon(Icons.build, size: 14, color: _mutedInk(context)),
            const SizedBox(width: 6),
            Text(l10n.voiceToolCalled(entry.text), style: _mutedStyle(context)),
          ],
        ),
        VoiceEntryKind.system => Text(
          _systemLabel(l10n, entry.text),
          textAlign: TextAlign.center,
          style: _mutedStyle(context),
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
          style: _mutedStyle(context),
        ),
        VoiceEntryKind.event => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.notifications_none, size: 14, color: _mutedInk(context)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _eventLabel(l10n, entry.text),
                style: _mutedStyle(context),
              ),
            ),
          ],
        ),
      },
    );
  }

  /// The draft [id] as a card: a header, the full text, and an action
  /// button while it is still pending — Send for a message, Launch for a new
  /// agent. Once acted on the button goes and the header shows a check; the
  /// "sent" statement itself is the [VoiceEntryKind.sent] line, so it appears
  /// exactly once. It sits in the log like an assistant bubble.
  Widget _draftCard(BuildContext context, AppLocalizations l10n, String id) {
    final scheme = Theme.of(context).colorScheme;
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
                color: _mutedInk(context),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  header,
                  style: droverLabelStyle(context, color: _mutedInk(context)),
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

/// The assistant's presence: light bleeding in from the edges of the screen
/// — a wash of the page's ink rising off the whole bottom edge, wrapping
/// round both bottom corners and climbing part-way up the sides, the way a
/// lamp on the floor lights the foot of a wall. A vignette, not a shape: no
/// outline, nothing that reads as an object, and nothing that moves on its
/// own. [level] — the voice actually in the room — is the only thing that
/// drives it: how bright it is, how far up it reaches, and how much of the
/// speaker's colour it carries.
class _EdgeGlow extends StatelessWidget {
  const _EdgeGlow({required this.level, required this.speaking});

  /// The session's smoothed 0..1 audio level. Already smoothed upstream, so
  /// it drives the glow directly — no second easing layer here.
  final ValueListenable<double> level;

  /// Whether the assistant holds the floor, which picks the tint. A plain
  /// field, not a listenable: the screen rebuilds on every session notify,
  /// and the session notifies at both ends of a turn.
  final bool speaking;

  /// ponytail: all of these are a by-eye knob, not derived — to be tuned on
  /// a device. [_alphaMin] is the resting presence (never zero: silence is
  /// still someone in the room); [_reachMin]/[_reachMax] are the fraction of
  /// the body the bottom wash climbs, [_sideReachMin]/[_sideReachMax] the
  /// fraction the side glow climbs, and [_sideWidth] how far in from the
  /// side edge it reaches, as a fraction of the width.
  static const _alphaMin = 0.52;
  static const _alphaMax = 1.0;
  static const _reachMin = 0.3;
  static const _reachMax = 0.52;
  static const _sideReachMin = 0.32;
  static const _sideReachMax = 0.4;
  static const _sideWidth = 0.25;

  /// Alpha of the ink along the bottom edge, and of the side glow at the
  /// very corner. They overlap only in the corners, so the most ink any
  /// pixel carries is `1 - (1 - 0.31)(1 - 0.14)` ≈ 0.41, and that is what
  /// text has to be read against; [_mutedInk] clears it on both themes.
  ///
  /// 1.4x the first pass's 0.22/0.10 — the glow read as weak on a device.
  static const _washAlpha = 0.31;
  static const _sideAlpha = 0.14;

  /// The side glow's alpha at 0, ¼, ½, ¾ and all of its radius, as a
  /// fraction of [_sideAlpha]: `(1 + cos(πr)) / 2`.
  static const _sideFalloff = [1.0, 0.85, 0.5, 0.15, 0.0];

  /// How long the tint takes to follow the floor changing hands. [speaking]
  /// flips in one step, and light that snapped colour would read as a cut.
  static const _tintDuration = Duration(milliseconds: 400);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The glow is only ever the floor-holder's colour. Silence is not a
    // separate, neutral state: nobody talking means the assistant is
    // listening, so a quiet room is the cool light, faint. The level scales
    // the alpha, never the hue.
    final ink = speaking
        ? (dark ? _speakingInkDark : _speakingInkLight)
        : voiceListeningInk(context);
    // Reduce motion reads as a permanently silent room: fixed at rest, not
    // subscribed to the level at all, and no tween to disable.
    if (MediaQuery.disableAnimationsOf(context)) return _glow(ink, 0);
    // A finite implicit tween on a state flip — no controller, no ticker
    // outliving the transition: the glow is still driven by the level alone.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: ink),
      duration: _tintDuration,
      builder: (context, tint, _) => ValueListenableBuilder<double>(
        valueListenable: level,
        builder: (context, value, _) =>
            _glow(tint ?? ink, value.clamp(0.0, 1.0)),
      ),
    );
  }

  /// The glow at level [v] in [ink] — the floor-holder's colour, mid-tween
  /// between the two when the floor has just changed hands. [v] scales both
  /// the alpha and how far up the body the light climbs. The alpha is
  /// multiplied into the gradients rather than applied with an [Opacity]:
  /// these washes overlap, so group
  /// opacity cannot fold into one draw and would cost a screen-wide
  /// offscreen layer on every audio frame, uncacheable because the boxes
  /// resize on the same tick.
  Widget _glow(Color ink, double v) {
    final k = _alphaMin + (_alphaMax - _alphaMin) * v;
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            key: const ValueKey('voice_edge_glow'),
            widthFactor: 1,
            heightFactor: _reachMin + (_reachMax - _reachMin) * v,
            // Light off an edge is a vertical fade, so the wash is a
            // LinearGradient: full strength along the whole bottom edge, 0
            // at the box's top, so there is no hard line and no readable arc.
            child: DecoratedBox(
              key: const ValueKey('voice_edge_wash'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    ink.withValues(alpha: _washAlpha * k),
                    ink.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
        // The sides: one quarter-ellipse of light in each bottom corner,
        // brightest at the corner and fading both inward and upward, so the
        // wash wraps the corner and climbs the side edge instead of stopping
        // in a straight line. A RadialGradient sizes its circle off the
        // box's *shortest* side, so on its own it would stop well short of
        // the top of a tall strip; [_CornerEllipse] stretches it to the box.
        for (final corner in const [
          Alignment.bottomLeft,
          Alignment.bottomRight,
        ])
          Align(
            alignment: corner,
            child: FractionallySizedBox(
              widthFactor: _sideWidth,
              heightFactor: _sideReachMin + (_sideReachMax - _sideReachMin) * v,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: corner,
                    radius: 1,
                    // A raised cosine, not a straight ramp: a soft foot at
                    // the corner, the drop in the middle, and a tail that
                    // meets zero flat, so there is no rim to read as a disc.
                    colors: [
                      for (final f in _sideFalloff)
                        ink.withValues(alpha: _sideAlpha * k * f),
                    ],
                    stops: const [0, 0.25, 0.5, 0.75, 1],
                    transform: _CornerEllipse(corner),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Stretches a [RadialGradient] anchored at [corner] — whose circle has the
/// radius of the box's shortest side — into the ellipse that fills the box,
/// by scaling about the corner. No layer: it is just the shader's matrix.
class _CornerEllipse extends GradientTransform {
  const _CornerEllipse(this.corner);

  final Alignment corner;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final c = corner.withinRect(bounds);
    final short = bounds.shortestSide;
    return Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(
        Matrix4.diagonal3Values(bounds.width / short, bounds.height / short, 1),
      )
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
  }
}
