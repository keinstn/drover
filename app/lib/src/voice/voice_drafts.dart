import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/agent_info.dart';

/// A message the model composed for an agent, awaiting the user's yes.
class VoiceDraft {
  const VoiceDraft({
    required this.id,
    required this.agent,
    required this.message,
  });

  final String id;
  final AgentInfo agent;
  final String message;
}

enum VoiceDraftEventKind { drafted, sent }

class VoiceDraftEvent {
  const VoiceDraftEvent(this.kind, this.draft);

  final VoiceDraftEventKind kind;
  final VoiceDraft draft;
}

/// Tracks message drafts for one voice session. Sending is not done here:
/// the tools and [VoiceSession.sendDraft] deliver, then call [markSent], so
/// a draft counts as sent only when the app actually sent it.
class VoiceDrafts extends ChangeNotifier {
  final _pending = <VoiceDraft>[];

  /// Every draft ever added, so a sent one stays renderable in the log.
  final _all = <String, VoiceDraft>{};
  final _events = StreamController<VoiceDraftEvent>.broadcast();
  var _nextId = 1;

  /// Drafts not yet sent, in insertion order.
  List<VoiceDraft> get pending => UnmodifiableListView(_pending);

  Stream<VoiceDraftEvent> get events => _events.stream;

  VoiceDraft add(AgentInfo agent, String message) {
    final draft = VoiceDraft(
      id: 'd${_nextId++}',
      agent: agent,
      message: message,
    );
    _pending.add(draft);
    _all[draft.id] = draft;
    notifyListeners();
    _events.add(VoiceDraftEvent(VoiceDraftEventKind.drafted, draft));
    return draft;
  }

  /// The draft with [id], pending or already sent; null if unknown.
  VoiceDraft? byId(String id) => _all[id];

  bool isPending(VoiceDraft draft) => _pending.contains(draft);

  /// Records that [draft] was delivered. A no-op for a draft not pending.
  void markSent(VoiceDraft draft) {
    if (!_pending.remove(draft)) return;
    notifyListeners();
    _events.add(VoiceDraftEvent(VoiceDraftEventKind.sent, draft));
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
