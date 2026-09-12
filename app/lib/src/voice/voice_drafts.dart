import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/agent_info.dart';

/// Something the model composed, awaiting the user's yes: a message for a
/// running agent, or a new agent to launch.
sealed class VoiceDraft {
  const VoiceDraft(this.id);

  final String id;
}

class MessageDraft extends VoiceDraft {
  const MessageDraft(super.id, {required this.agent, required this.message});

  final AgentInfo agent;
  final String message;
}

/// A coding agent to start: [kind] is an agent preset kind (e.g. `claude`),
/// [cwd] the project directory it runs in, and [brief] the task text the
/// model wrote for it.
class LaunchDraft extends VoiceDraft {
  const LaunchDraft(
    super.id, {
    required this.kind,
    required this.cwd,
    required this.brief,
  });

  final String kind;
  final String cwd;
  final String brief;
}

enum VoiceDraftEventKind { drafted, sent }

class VoiceDraftEvent {
  const VoiceDraftEvent(this.kind, this.draft);

  final VoiceDraftEventKind kind;
  final VoiceDraft draft;
}

/// Tracks the drafts of one voice session. Delivery is not done here: the
/// tools and [VoiceSession.sendDraft] / [VoiceSession.launchDraft] act, then
/// call [markSent], so a draft counts as done only when the app did it.
class VoiceDrafts extends ChangeNotifier {
  final _pending = <VoiceDraft>[];

  /// Every draft ever added, so a sent one stays renderable in the log.
  final _all = <String, VoiceDraft>{};
  final _events = StreamController<VoiceDraftEvent>.broadcast();

  /// Ids of drafts currently being delivered; see [isBusy].
  final _busy = <String>{};
  var _nextId = 1;

  /// Drafts not yet sent, in insertion order.
  List<VoiceDraft> get pending => UnmodifiableListView(_pending);

  Stream<VoiceDraftEvent> get events => _events.stream;

  MessageDraft add(AgentInfo agent, String message) =>
      _add(MessageDraft('d${_nextId++}', agent: agent, message: message));

  LaunchDraft addLaunch({
    required String kind,
    required String cwd,
    required String brief,
  }) => _add(LaunchDraft('d${_nextId++}', kind: kind, cwd: cwd, brief: brief));

  T _add<T extends VoiceDraft>(T draft) {
    _pending.add(draft);
    _all[draft.id] = draft;
    notifyListeners();
    _events.add(VoiceDraftEvent(VoiceDraftEventKind.drafted, draft));
    return draft;
  }

  /// The draft with [id], pending or already sent; null if unknown.
  VoiceDraft? byId(String id) => _all[id];

  bool isPending(VoiceDraft draft) => _pending.contains(draft);

  /// True while the app is delivering [draft]. Starting a second delivery
  /// would leave voicemail twice — or, for a launch, start a second agent in
  /// a second workspace — so both the tool and the screen refuse one.
  bool isBusy(VoiceDraft draft) => _busy.contains(draft.id);

  void markBusy(VoiceDraft draft) {
    if (_busy.add(draft.id)) notifyListeners();
  }

  void release(VoiceDraft draft) {
    if (_busy.remove(draft.id)) notifyListeners();
  }

  /// Records that [draft] was delivered — launched, for a launch draft. A
  /// no-op for a draft not pending.
  void markSent(VoiceDraft draft) {
    if (!_pending.remove(draft)) return;
    _busy.remove(draft.id);
    notifyListeners();
    _events.add(VoiceDraftEvent(VoiceDraftEventKind.sent, draft));
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
