import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/agent_info.dart';
import '../transcript/native_transcript.dart';
import 'speech_input.dart';
import 'speech_output.dart';

final _fence = RegExp(r'^\s*(```|~~~)');
final _tableRow = RegExp(r'^\s*\|');
final _rule = RegExp(r'^\s*([-*_]\s*){3,}$');
final _blockMarker = RegExp(r'^\s*((>\s?)+|#{1,6}\s+|([-*+]|\d+[.)])\s+)+');
final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final _inlineCode = RegExp(r'`+([^`]*)`+');
final _url = RegExp(r'https?://\S+');
final _strong = RegExp(r'(\*\*|__)(.+?)\1');
final _em = RegExp(r'\*(.+?)\*|(?<!\w)_(.+?)_(?!\w)');
final _strike = RegExp(r'~~(.+?)~~');
final _spaces = RegExp(r'[ \t　]+');

/// Reduces an assistant's markdown to what is worth hearing. Code blocks and
/// tables are dropped outright: read aloud they are noise, and the user can
/// look at the screen for them. Line breaks are kept.
String speakableText(String markdown) {
  final lines = <String>[];
  var inFence = false;
  for (final raw in markdown.split('\n')) {
    if (_fence.hasMatch(raw)) {
      inFence = !inFence;
      continue;
    }
    if (inFence || _tableRow.hasMatch(raw) || _rule.hasMatch(raw)) continue;
    final line = raw
        .replaceFirst(_blockMarker, '')
        .replaceAllMapped(_image, (m) => m[1]!)
        .replaceAllMapped(_link, (m) => m[1]!)
        .replaceAllMapped(_inlineCode, (m) => m[1]!)
        .replaceAll(_url, '')
        .replaceAllMapped(_strong, (m) => m[2]!)
        .replaceAllMapped(_em, (m) => m[1] ?? m[2]!)
        .replaceAllMapped(_strike, (m) => m[1]!)
        .replaceAll(_spaces, ' ')
        .trim();
    if (line.isNotEmpty) lines.add(line);
  }
  return lines.join('\n');
}

enum ConversationPhase { off, listening, sending, waiting, speaking, paused }

enum ConversationPauseReason { noSpeech, blocked, error, tapped }

/// Drives the listen → send → speak-the-reply → listen loop for one agent.
///
/// The screen feeds it each poll through [onUpdate]; it never polls itself.
class ConversationController extends ChangeNotifier {
  ConversationController({
    required this._input,
    required this._output,
    required this._send,
    required this.localeTag,
    this.pauseFor = const Duration(seconds: 4),
  });

  final SpeechInput _input;
  final SpeechOutput _output;
  final Future<bool> Function(String text) _send;
  final String localeTag;
  final Duration pauseFor;

  ConversationPhase phase = ConversationPhase.off;
  String partialWords = '';
  ConversationPauseReason? pauseReason;

  /// Bumped whenever an in-flight listen, send or speak loses its claim on
  /// the conversation (tap, pause, stop, dispose), so its late callbacks are
  /// dropped.
  int _session = 0;
  AgentStatus? _lastStatus;

  /// The text of the current turn's send; null when no turn is pending.
  String? _anchor;

  /// User messages in the latest poll, and how many there were when the
  /// current turn was sent. The turn has landed only once a NEW user message
  /// carrying the anchor shows up; matching text alone would latch onto an
  /// older identical message (a second "OK", or the style instruction after
  /// toggling the mode off and on) in the poll before the send lands.
  int _userMessages = 0;
  int _userMessagesAtSend = 0;
  int _queuedReplies = 0;
  bool _spokeThisTurn = false;
  bool _sawWorking = false;
  final _queue = <String>[];
  bool _speaking = false;

  /// Starts the conversation by sending [styleInstruction]; the agent's
  /// acknowledgement is read out like any other reply.
  void start(String styleInstruction) {
    pauseReason = null;
    unawaited(_sendTurn(styleInstruction));
  }

  void stop() {
    _reset();
    phase = ConversationPhase.off;
    pauseReason = null;
    partialWords = '';
    notifyListeners();
  }

  void tap() {
    switch (phase) {
      // Waiting is included so a turn that never shows a sign of life (see
      // [_maybeEndTurn]) can't strand the user without the header toggle.
      case ConversationPhase.speaking:
      case ConversationPhase.paused:
        unawaited(_listen());
      // Not while the agent works: an interjection then is queued by the
      // agent (Claude's queued_command) rather than recorded as a user
      // message, so its reply could never be matched and read back.
      case ConversationPhase.waiting:
        if (_lastStatus != AgentStatus.working) unawaited(_listen());
      case ConversationPhase.listening:
        final words = partialWords.trim();
        _session++;
        unawaited(_input.stop());
        if (words.isEmpty) {
          _pause(ConversationPauseReason.tapped);
        } else {
          unawaited(_sendTurn(words));
        }
      case ConversationPhase.off:
      case ConversationPhase.sending:
        break;
    }
  }

  void onUpdate(List<TranscriptEntry> entries, AgentStatus status) {
    _lastStatus = status;
    final lastUser = entries.lastIndexWhere(_isUserMessage);
    _userMessages = entries.where(_isUserMessage).length;
    if (phase == ConversationPhase.off) return;
    if (status == AgentStatus.blocked) {
      if (phase != ConversationPhase.paused) {
        _pause(ConversationPauseReason.blocked);
      }
      return;
    }
    final anchor = _anchor;
    if (anchor == null) return;
    if (status == AgentStatus.working) _sawWorking = true;

    // Adapters may re-parse the whole transcript into fresh instances every
    // poll, so the turn is located by counts and by the text we sent (a user
    // message can carry wrappers around it), never by identity.
    final landed =
        _userMessages > _userMessagesAtSend &&
        (entries[lastUser] as TranscriptMessage).text.contains(anchor);
    if (landed) {
      final replies = entries
          .skip(lastUser + 1)
          .whereType<TranscriptMessage>()
          .where((m) => m.speaker == TranscriptSpeaker.assistant)
          .toList();
      for (final reply in replies.skip(_queuedReplies)) {
        // One utterance per reply: sentence-sized ones reset the intonation.
        final text = speakableText(reply.text);
        if (text.isNotEmpty) _queue.add(text);
      }
      if (replies.length > _queuedReplies) _queuedReplies = replies.length;
    }
    unawaited(_speakQueue());
    _maybeEndTurn();
  }

  static bool _isUserMessage(TranscriptEntry e) =>
      e is TranscriptMessage && e.speaker == TranscriptSpeaker.user;

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _reset() {
    _session++;
    _anchor = null;
    _queue.clear();
    _speaking = false;
    unawaited(_input.cancel());
    unawaited(_output.stop());
  }

  void _pause(ConversationPauseReason reason) {
    _reset();
    phase = ConversationPhase.paused;
    pauseReason = reason;
    notifyListeners();
  }

  Future<void> _sendTurn(String text) async {
    if (_lastStatus == AgentStatus.blocked) {
      _pause(ConversationPauseReason.blocked);
      return;
    }
    final session = _session;
    _anchor = text.trim();
    _userMessagesAtSend = _userMessages;
    _queuedReplies = 0;
    _spokeThisTurn = false;
    _sawWorking = false;
    phase = ConversationPhase.sending;
    notifyListeners();
    final sent = await _send(text);
    if (session != _session) return;
    if (!sent) {
      _pause(ConversationPauseReason.error);
    } else if (phase == ConversationPhase.sending) {
      phase = ConversationPhase.waiting;
      notifyListeners();
      _maybeEndTurn();
    }
  }

  Future<void> _speakQueue() async {
    if (_speaking || _queue.isEmpty) return;
    final session = _session;
    _speaking = true;
    _spokeThisTurn = true;
    phase = ConversationPhase.speaking;
    notifyListeners();
    while (_queue.isNotEmpty) {
      try {
        await _output.speak(_queue.removeAt(0), localeTag: localeTag);
      } catch (_) {
        // Otherwise the phase would stay at speaking with nothing left to
        // end it.
        if (session == _session) _pause(ConversationPauseReason.error);
        return;
      }
      if (session != _session) return;
    }
    _speaking = false;
    phase = ConversationPhase.waiting;
    notifyListeners();
    _maybeEndTurn();
  }

  /// Re-opens the mic once the agent's turn is over. An idle status alone
  /// isn't enough: right after a send the agent may not have picked the
  /// message up yet, so the turn must also have shown some sign of life: a
  /// reply was spoken, a poll caught it working, or a reply arrived with
  /// nothing speakable in it (all code).
  void _maybeEndTurn() {
    if (phase != ConversationPhase.waiting ||
        _speaking ||
        _queue.isNotEmpty ||
        _lastStatus == null ||
        _lastStatus == AgentStatus.working ||
        !(_spokeThisTurn || _sawWorking || _queuedReplies > 0)) {
      return;
    }
    unawaited(_listen());
  }

  Future<void> _listen() async {
    _session++;
    _anchor = null;
    _queue.clear();
    if (_speaking) {
      _speaking = false;
      unawaited(_output.stop());
    }
    final session = _session;
    phase = ConversationPhase.listening;
    pauseReason = null;
    partialWords = '';
    notifyListeners();
    final result = await _input.start(
      pauseFor: pauseFor,
      onResult: (result) {
        if (session != _session) return;
        partialWords = result.words;
        notifyListeners();
        if (result.isFinal) _finishListening();
      },
      onStatus: (status) {
        if (session != _session || status != SpeechInputStatus.done) return;
        _finishListening();
      },
      onError: (_) {
        if (session != _session) return;
        _pause(ConversationPauseReason.error);
      },
    );
    if (session != _session) return;
    if (!result.started) _pause(ConversationPauseReason.error);
  }

  /// Ends a listen with whatever was heard. An empty listen pauses instead of
  /// re-listening, so silence can't keep the mic open in a loop.
  void _finishListening() {
    final words = partialWords.trim();
    _session++;
    if (words.isEmpty) {
      _pause(ConversationPauseReason.noSpeech);
      return;
    }
    unawaited(_input.stop());
    unawaited(_sendTurn(words));
  }
}
