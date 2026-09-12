import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import 'voice_drafts.dart';
import 'voice_herd.dart';
import 'voice_session.dart';

/// The voice-assistant conversation: a status line, the transcript log and
/// an End/Restart button. Owns the [session] lifecycle: starts it on first
/// frame, disposes it with the screen.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.session});

  final VoiceSession session;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _scroll = ScrollController();

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = widget.session;
    final scheme = Theme.of(context).colorScheme;
    final tertiary = DroverColors.of(context).tertiaryText;
    final rows = <Widget>[
      for (final entry in session.entries) _entryRow(context, l10n, entry),
      if (session.partialUser case final text?)
        _entryRow(context, l10n, VoiceEntry(VoiceEntryKind.user, text)),
      if (session.partialAssistant case final text?)
        _entryRow(context, l10n, VoiceEntry(VoiceEntryKind.assistant, text)),
    ];
    final active =
        session.status == VoiceSessionStatus.connecting ||
        session.status == VoiceSessionStatus.live;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.voiceTitle)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              _statusLabel(l10n, session),
              key: const ValueKey('voice_status'),
              style: droverLabelStyle(context, color: tertiary),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.voiceHint,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: rows,
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                key: const ValueKey('voice_action_button'),
                onPressed: active ? session.stop : session.start,
                icon: Icon(active ? Icons.stop : Icons.refresh),
                label: Text(active ? l10n.voiceEnd : l10n.voiceRestart),
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
        VoiceSessionStatus.live => l10n.voiceStatusLive,
        VoiceSessionStatus.ended => l10n.voiceStatusEnded,
        VoiceSessionStatus.error => l10n.voiceStatusError(
          session.error == VoiceSession.micPermissionDenied
              ? l10n.voiceMicPermissionDenied
              : session.error ?? '',
        ),
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
          switch (entry.text) {
            VoiceSession.interruptedCode => l10n.voiceInterrupted,
            VoiceSession.goingAwayCode => l10n.voiceGoingAway,
            VoiceSession.endedCode => l10n.voiceEnded,
            VoiceSession.announceFailedCode => l10n.voiceEventAnnounceFailed,
            VoiceSession.unsentDraftsCode => l10n.voiceUnsentDrafts,
            VoiceSession.sendFailedCode => l10n.voiceSendFailed,
            _ => entry.text,
          },
          textAlign: TextAlign.center,
          style: muted,
        ),
        VoiceEntryKind.draft => _draftCard(context, l10n, entry.text),
        VoiceEntryKind.sent => Text(
          l10n.voiceDraftSent(
            voiceAgentTitle(widget.session.drafts.byId(entry.text)!.agent),
          ),
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

  /// The draft [id] as a card: agent header, message, and a Send button
  /// while it is still pending. Once sent the button goes and the header
  /// shows a check; the "sent" statement itself is the [VoiceEntryKind.sent]
  /// line, so it appears exactly once.
  Widget _draftCard(BuildContext context, AppLocalizations l10n, String id) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    final drafts = widget.session.drafts;
    final VoiceDraft draft = drafts.byId(id)!;
    final pending = drafts.isPending(draft);
    final title = voiceAgentTitle(draft.agent);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Container(
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
                    pending ? Icons.schedule_send : Icons.check,
                    size: 14,
                    color: colors.tertiaryText,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pending ? l10n.voiceDraftPending(title) : title,
                      style: droverLabelStyle(
                        context,
                        color: colors.tertiaryText,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                draft.message,
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
                    key: ValueKey('voice_draft_send_$id'),
                    onPressed: () => widget.session.sendDraft(id),
                    child: Text(l10n.voiceDraftSend),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

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
