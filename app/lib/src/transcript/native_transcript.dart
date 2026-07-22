import 'dart:convert';
import 'dart:math';

import '../models/agent_info.dart';

enum TranscriptSpeaker { user, assistant }

/// One entry in a rendered transcript: a chat message, a tool invocation, or
/// a thinking block, in the order the agent produced them. Shared by every
/// agent's native transcript source (see `NativeTranscriptAdapter`); an
/// agent's own module is responsible for parsing its raw format into this
/// shape.
sealed class TranscriptEntry {
  const TranscriptEntry();
}

class TranscriptMessage extends TranscriptEntry {
  const TranscriptMessage({required this.speaker, required this.text});

  final TranscriptSpeaker speaker;
  final String text;
}

class TranscriptToolUse extends TranscriptEntry {
  const TranscriptToolUse({required this.name, required this.input, this.id});

  final String name;
  final Map<String, dynamic> input;
  final String? id;
}

class TranscriptThinking extends TranscriptEntry {
  const TranscriptThinking(this.text);

  final String text;
}

/// A marker for a tool_result block seen in a later USER record, matched to
/// its originating [TranscriptToolUse] by [toolUseId].
class TranscriptToolResult extends TranscriptEntry {
  const TranscriptToolResult(this.toolUseId);

  final String toolUseId;
}

/// One selectable option within a [StructuredPromptQuestion]. A common,
/// agent-agnostic shape — an agent's own module (e.g. `agents/claude`) is
/// responsible for parsing its native record (Claude's AskUserQuestion tool,
/// say) into this shape.
class StructuredPromptOption {
  const StructuredPromptOption({required this.label, this.description});

  final String label;
  final String? description;
}

/// One question within a [StructuredPrompt].
class StructuredPromptQuestion {
  const StructuredPromptQuestion({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });

  final String question;
  final String header;
  final bool multiSelect;
  final List<StructuredPromptOption> options;
}

/// An agent's pending interactive structured prompt (e.g. the parsed input of
/// Claude Code's AskUserQuestion tool_use), keyed by [id] — an
/// implementation-defined identifier (a tool_use id, say) that its eventual
/// answer/acknowledgement must match.
class StructuredPrompt {
  const StructuredPrompt({required this.id, required this.questions});

  final String id;
  final List<StructuredPromptQuestion> questions;
}

/// A user's answer to one [StructuredPromptQuestion]. Single-select answers
/// have at most one selected index; a custom answer sets [customText] instead.
class StructuredPromptAnswer {
  const StructuredPromptAnswer({
    required this.selectedIndexes,
    this.customText,
  });

  final List<int> selectedIndexes;
  final String? customText;
}

/// The cap every [toolUseSummary] branch truncates its return value to, so a
/// huge or multi-line input can never grow the summary the UI keys and lays
/// out on every poll.
const _summaryMaxLength = 100;

/// A one-line summary for a tool_use entry, keyed by tool name. Every
/// accessor tolerates missing or wrong-shaped input rather than throwing, and
/// every return value is collapsed to its first line and length-capped.
String toolUseSummary(String name, Map<String, dynamic> input) {
  switch (name) {
    case 'Read':
    case 'Edit':
    case 'Write':
      return _summarize(input['file_path']);
    case 'Bash':
      return _summarize(input['command']);
    case 'Grep':
    case 'Glob':
      return _summarize(input['pattern']);
    case 'Task':
      return _summarize(input['description']);
    case 'WebFetch':
      return _summarize(input['url']);
    case 'WebSearch':
      return _summarize(input['query']);
    case 'AskUserQuestion':
      final questions = input['questions'];
      if (questions is List && questions.isNotEmpty) {
        final first = questions.first;
        if (first is Map) {
          return _summarize(first['question']);
        }
      }
      return '';
    default:
      for (final value in input.values) {
        if (value is String) return _summarize(value);
      }
      return '';
  }
}

String _summarize(dynamic value) =>
    _truncate(_firstLine(_asString(value)), _summaryMaxLength);

String _asString(dynamic value) => value is String ? value : '';

String _firstLine(String text) => text.split('\n').first;

String _truncate(String text, int maxLength) =>
    text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';

class NativeTranscript {
  const NativeTranscript(this.entries);

  final List<TranscriptEntry> entries;

  /// Compat view for UI code that only renders chat messages.
  List<TranscriptMessage> get messages =>
      entries.whereType<TranscriptMessage>().toList();
}

/// A native agent-specific transcript source. More agent formats can be
/// added without coupling their parsing or storage details to the screen.
/// Resolved per agent by an `AgentAdapter`'s `createNativeHistory` factory —
/// see `NativeHistoryCapability` and `NativeTranscriptHistory`.
abstract interface class NativeTranscriptAdapter {
  Future<NativeTranscript?> load(AgentInfo agent);

  /// Whether an older, not-yet-loaded chunk of history exists before the
  /// window [load] has fetched so far. False before an initial [load] has
  /// established a window, and false once that window reaches the beginning
  /// of the underlying file — so pull-to-load-more can stop cleanly.
  bool get hasOlderHistory => false;

  /// Fetches and prepends the next older bounded chunk (see
  /// [nativeTranscriptWindowBytes]), returning the updated transcript with
  /// older entries moved to the front in the same chronological order, or
  /// null when there is nothing older to load — also true before an initial
  /// [load], for an adapter that doesn't support paging older history at
  /// all, or once [hasOlderHistory] is false.
  Future<NativeTranscript?> loadOlder(AgentInfo agent) => Future.value(null);
}

/// The byte size of the bounded window fetched for the very first [load] of
/// a large native transcript file, and for each subsequent older-history
/// chunk fetched via [NativeTranscriptAdapter.loadOlder]. Kept well under a
/// typical transcript's full size (which can run 20-50+ MiB) so opening a
/// pane never has to transfer more than this up front, while still covering
/// many turns of typical JSONL records.
const nativeTranscriptWindowBytes = 512 * 1024;

/// Reads the current byte size of the file backing a [JsonlTranscriptWindow].
typedef NativeTranscriptStatReader = Future<int> Function();

/// Reads bytes from the file backing a [JsonlTranscriptWindow]: at most
/// [length] bytes (or through EOF when null) starting at [offset].
typedef NativeTranscriptRangeReader =
    Future<List<int>> Function(int offset, int? length);

/// Shared byte-window/offset/partial-line bookkeeping behind Claude's and
/// Copilot's otherwise-identical JSONL transcript loaders (see
/// `ClaudeTranscriptLoader`, `CopilotTranscriptLoader`). An agent's own
/// loader owns locating/validating the remote path and its own record
/// parsing (a JSONL line -> [TranscriptEntry] function); this class owns:
///
///  - the very first read of a large file being a bounded tail (the last
///    [nativeTranscriptWindowBytes]) rather than the whole file from offset
///    0, so opening a 50 MiB transcript never transfers it all;
///  - discarding the partial JSONL record such a bounded window may begin
///    mid-line (only the leading partial record is ever discarded — see
///    [_resolveFromConfirmedEdge]);
///  - append-only polling that transfers only the bytes written after the
///    known EOF, never re-downloading already-loaded chunks;
///  - explicit "older" bounded-chunk loads ([loadOlder]) that prepend
///    earlier history in chronological order, until the beginning of the
///    file is reached ([hasOlder] becomes false);
///  - a single record wider than [windowBytes] (e.g. a huge tool result)
///    never causing more than one bounded range read per [loadOlder]/initial
///    [loadOrAppend] call: such a record is simply omitted rather than
///    retried with a growing/duplicate read (see [_pendingOlderEnd]);
///  - safely resetting all of the above on truncation or a replaced file.
class JsonlTranscriptWindow {
  /// [windowBytes] is exposed so tests can use a small window without a
  /// multi-hundred-KiB fixture; production code should use the default.
  JsonlTranscriptWindow({this.windowBytes = nativeTranscriptWindowBytes});

  final int windowBytes;

  // The offset of the first byte covered by [_entries]; null before any
  // load has established a window. While [_pendingOlderEnd] is set, this is
  // a not-yet-confirmed sentinel (just enough to keep [hasOlder] true) —
  // the real next-read boundary is [_pendingOlderEnd] until traversal
  // resolves.
  int? _windowStart;
  // The offset one past the last byte read so far; the next append read
  // starts here and reads through to EOF.
  var _readEnd = 0;
  // A trailing partial JSONL line kept across reads/polls until a later read
  // completes it (see [_appendBytes]).
  var _remainder = '';
  var _remainderParsed = false;
  final _entries = <TranscriptEntry>[];
  // Set while traversing a record wider than [windowBytes]: the offset the
  // *next* older-page read should end at, in place of [_windowStart] (which
  // stays an unconfirmed sentinel until a genuine record boundary is found).
  // Each unresolved read moves this strictly backward to that read's own
  // start, so the next call reads fresh, non-overlapping bytes rather than
  // stalling or re-reading the same span. Null when there is no such
  // traversal in progress, i.e. [_windowStart] itself is the confirmed next
  // boundary.
  int? _pendingOlderEnd;

  /// True once an initial load has established a window whose start is not
  /// yet byte 0 of the file — i.e. [loadOlder] has more to fetch.
  bool get hasOlder => _windowStart != null && _windowStart! > 0;

  /// True once an initial load has completed (successfully, even with zero
  /// entries parsed), i.e. [snapshot] reflects real (if possibly empty) file
  /// content rather than the pre-load empty state.
  bool get hasLoaded => _windowStart != null;

  NativeTranscript get snapshot =>
      NativeTranscript(List.unmodifiable(_entries));

  /// Clears all window/offset/parse state, e.g. when the session identity
  /// changes or the backing file is replaced/truncated.
  void reset() {
    _windowStart = null;
    _readEnd = 0;
    _remainder = '';
    _remainderParsed = false;
    _pendingOlderEnd = null;
    _entries.clear();
  }

  /// Loads the initial bounded window, or appends newly-written bytes on a
  /// later poll — whichever applies given the window's current state and
  /// the file's current [statSize]. Detects truncation (the file shrank
  /// below what has already been read, e.g. a new session reusing a path)
  /// and [reset]s before reading, so a stale window is never mixed with a
  /// different file's content.
  Future<NativeTranscript> loadOrAppend({
    required NativeTranscriptStatReader statSize,
    required NativeTranscriptRangeReader readRange,
    required List<TranscriptEntry> Function(String input) parseLines,
    required List<TranscriptEntry> Function(String line) parseLine,
  }) async {
    final size = await statSize();
    if (size < _readEnd) {
      reset();
    }
    if (_windowStart == null) {
      if (size == 0) {
        // Nothing to read; the empty file is trivially the whole window.
        _windowStart = 0;
        _readEnd = 0;
        return snapshot;
      }
      return _loadInitial(
        size: size,
        readRange: readRange,
        parseLines: parseLines,
        parseLine: parseLine,
      );
    }
    if (size == _readEnd) {
      return snapshot;
    }
    final bytes = await readRange(_readEnd, null);
    _readEnd += bytes.length;
    _appendBytes(bytes, parseLines: parseLines, parseLine: parseLine);
    return snapshot;
  }

  Future<NativeTranscript> _loadInitial({
    required int size,
    required NativeTranscriptRangeReader readRange,
    required List<TranscriptEntry> Function(String input) parseLines,
    required List<TranscriptEntry> Function(String line) parseLine,
  }) async {
    if (size <= windowBytes) {
      // Small enough to load in full, exactly like the pre-windowed loader.
      final bytes = await readRange(0, null);
      _windowStart = 0;
      _readEnd = bytes.length;
      _appendBytes(bytes, parseLines: parseLines, parseLine: parseLine);
      return snapshot;
    }
    final raw = await _readRaw(endOffset: size, readRange: readRange);
    _readEnd = raw.offset + raw.bytes.length;
    final resolved = _resolveFromConfirmedEdge(raw);
    if (resolved != null) {
      _windowStart = resolved.windowStart;
      _appendBytes(
        resolved.clean,
        parseLines: parseLines,
        parseLine: parseLine,
      );
    } else {
      // The record reaching EOF is itself at least `windowBytes` wide — its
      // own leading boundary wasn't found in this single bounded read. Per
      // the class doc, that oversized trailing record is simply omitted:
      // leave `_windowStart` as a `hasOlder` sentinel (this initial read
      // has still made real progress — see `_pendingOlderEnd`, which the
      // next `loadOlder` call continues from instead of stalling on or
      // repeating this same span).
      _windowStart = size;
      _pendingOlderEnd = raw.offset;
    }
    return snapshot;
  }

  /// Fetches and prepends the next older bounded chunk, or returns null when
  /// [hasOlder] is false (also true before an initial load).
  Future<NativeTranscript?> loadOlder({
    required NativeTranscriptRangeReader readRange,
    required List<TranscriptEntry> Function(String input) parseLines,
  }) async {
    final windowStart = _windowStart;
    if (windowStart == null || windowStart <= 0) return null;
    final pending = _pendingOlderEnd;
    if (pending == null) {
      // Normal case: `windowStart` is an already-confirmed boundary.
      final raw = await _readRaw(endOffset: windowStart, readRange: readRange);
      final resolved = _resolveFromConfirmedEdge(raw);
      if (resolved == null) {
        // A record wider than `windowBytes` sits right before `windowStart`
        // with no boundary found in this one bounded read. Start traversing
        // it: `_windowStart` stays put (still confirmed, still keeps
        // `hasOlder` true) while `_pendingOlderEnd` carries this read's own
        // start for the next call to continue from, strictly backward.
        _pendingOlderEnd = raw.offset;
        return snapshot;
      }
      _windowStart = resolved.windowStart;
      _entries.insertAll(
        0,
        parseLines(utf8.decode(resolved.clean, allowMalformed: true)),
      );
      return snapshot;
    }
    // Resolving a pending oversized-record traversal: `pending` (this
    // read's own right edge) is itself not a confirmed boundary yet.
    final raw = await _readRaw(endOffset: pending, readRange: readRange);
    final resolved = _resolveFromPendingEdge(raw);
    if (resolved == null) {
      // Still inside the same oversized record: move the pending cursor
      // strictly backward to this read's own start so the next call reads
      // fresh, non-overlapping bytes instead of stalling or repeating this
      // span. `_windowStart` (still the pre-traversal sentinel) is
      // untouched, so `hasOlder` stays true.
      _pendingOlderEnd = raw.offset;
      return snapshot;
    }
    _windowStart = resolved.windowStart;
    _pendingOlderEnd = null;
    if (resolved.clean.isNotEmpty) {
      _entries.insertAll(
        0,
        parseLines(utf8.decode(resolved.clean, allowMalformed: true)),
      );
    }
    return snapshot;
  }

  /// Reads exactly the [windowBytes]-bounded (or smaller, near offset 0)
  /// span ending at [endOffset] — one single range read, never retried or
  /// grown within this call.
  Future<_RawRead> _readRaw({
    required int endOffset,
    required NativeTranscriptRangeReader readRange,
  }) async {
    final offset = max(0, endOffset - windowBytes);
    final length = endOffset - offset;
    final bytes = await readRange(offset, length);
    return _RawRead(offset: offset, bytes: bytes);
  }

  /// Resolves [raw] assuming its right edge (`raw.offset + raw.bytes.length`)
  /// is already a confirmed JSONL record boundary — true for every normal
  /// older-page read, and safe for the very first read of a large file too
  /// (a possibly-unterminated final record there is handled by
  /// [_appendBytes]'s remainder logic, not parsed here). Discards everything
  /// up to and including the first newline, so [_ResolvedChunk.clean] begins
  /// at a genuine record boundary. Returns null when no newline is found
  /// before the buffer's very last byte — i.e. one record spans the whole
  /// span with no leading boundary discovered yet (a newline *at* the very
  /// last byte is this confirmed edge itself, not new information, so it
  /// doesn't count either).
  _ResolvedChunk? _resolveFromConfirmedEdge(_RawRead raw) {
    if (raw.offset == 0) {
      return _ResolvedChunk(clean: raw.bytes, windowStart: 0);
    }
    final newline = raw.bytes.indexOf(0x0A);
    if (newline < 0 || newline == raw.bytes.length - 1) return null;
    return _ResolvedChunk(
      clean: raw.bytes.sublist(newline + 1),
      windowStart: raw.offset + newline + 1,
    );
  }

  /// Resolves [raw] when its right edge (`pending`, i.e. [_pendingOlderEnd])
  /// is *not* a confirmed boundary — reading further back while traversing a
  /// record wider than [windowBytes]. Unlike [_resolveFromConfirmedEdge],
  /// content right up to the buffer's end can't be trusted as complete, so:
  ///
  ///  - at the true start of the file ([_RawRead.offset] 0), this always
  ///    resolves — nothing more will ever be found further back — keeping
  ///    only whatever precedes the last newline found (if any) as
  ///    [_ResolvedChunk.clean], and discarding any trailing fragment after
  ///    it (the still-unbounded record this traversal was widening around);
  ///  - otherwise, if the last newline found is the buffer's very last byte,
  ///    that byte retroactively confirms `pending` as a real boundary after
  ///    all, so this degrades to exactly [_resolveFromConfirmedEdge]'s
  ///    first-newline logic;
  ///  - otherwise, only content bounded by two directly-observed newlines —
  ///    the first and the last found in this read — is trusted; anything
  ///    after the last one, up to `pending`, is left folded into the still
  ///    not-fully-bounded record for a later read to keep resolving.
  ///
  /// Returns null only when still fully unresolved (no usable boundary and
  /// not yet at the true file start), so the caller retries further back.
  _ResolvedChunk? _resolveFromPendingEdge(_RawRead raw) {
    final last = raw.bytes.lastIndexOf(0x0A);
    if (raw.offset == 0) {
      return _ResolvedChunk(
        clean: last < 0 ? const [] : raw.bytes.sublist(0, last + 1),
        windowStart: 0,
      );
    }
    if (last < 0) return null;
    if (last == raw.bytes.length - 1) {
      final first = raw.bytes.indexOf(0x0A);
      if (first == last) return null;
      return _ResolvedChunk(
        clean: raw.bytes.sublist(first + 1),
        windowStart: raw.offset + first + 1,
      );
    }
    final first = raw.bytes.indexOf(0x0A);
    return _ResolvedChunk(
      clean: first < last ? raw.bytes.sublist(first + 1, last + 1) : const [],
      windowStart: raw.offset + first + 1,
    );
  }

  /// Combines [bytes] with any pending [_remainder], appends every complete
  /// line's parsed entries to [_entries], and keeps a new trailing partial
  /// line (if any) as the remainder — tentatively parsing and appending it
  /// too (removed/replaced on the next call) so a final unterminated record
  /// still renders immediately rather than waiting for its newline.
  void _appendBytes(
    List<int> bytes, {
    required List<TranscriptEntry> Function(String input) parseLines,
    required List<TranscriptEntry> Function(String line) parseLine,
  }) {
    if (bytes.isEmpty) return;
    final appended = utf8.decode(bytes, allowMalformed: true);
    final completesParsedRemainder =
        _remainderParsed && appended.startsWith('\n');
    if (completesParsedRemainder) {
      _remainder = '';
      _remainderParsed = false;
    }
    final input = completesParsedRemainder
        ? appended.substring(1)
        : '$_remainder$appended';
    final lastNewline = input.lastIndexOf('\n');
    if (lastNewline < 0) {
      _remainder = input;
      final entries = parseLine(input);
      if (entries.isNotEmpty && !_remainderParsed) {
        _entries.addAll(entries);
        _remainderParsed = true;
      }
    } else {
      _entries.addAll(parseLines(input.substring(0, lastNewline)));
      _remainder = input.substring(lastNewline + 1);
      _remainderParsed = false;
      final entries = parseLine(_remainder);
      if (entries.isNotEmpty) {
        _entries.addAll(entries);
        _remainderParsed = true;
      }
    }
  }
}

/// Returns true if [value] matches the UUID v1–v5 pattern used as a
/// native-transcript session identity by Claude Code and Copilot CLI.
/// Both agents validate their session ids against this same pattern; sharing
/// it here avoids the two copies drifting apart.
bool isNativeTranscriptSessionId(String value) =>
    _sessionIdPattern.hasMatch(value);

final _sessionIdPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

/// Shared session-identity / path-cache / window orchestration for JSONL
/// native transcript loaders (see `ClaudeTranscriptLoader`,
/// `CopilotTranscriptLoader`). An agent's own loader owns locating/validating
/// the remote path and parsing JSONL lines into [TranscriptEntry] values; this
/// class owns:
///
///  - tracking the current session identity and resetting the path cache and
///    window whenever it changes (session switch or first call);
///  - caching the resolved path across polls so [locate] is called only once
///    per session identity rather than on every poll;
///  - delegating stat/range I/O and line parsing to the caller-supplied
///    functions so [JsonlTranscriptWindow]'s bounded-tail/append/older-page
///    logic applies uniformly.
///
/// This is a compositional helper, not a base class. Each concrete loader
/// constructs one instance and calls [load] / [loadOlder] with its own
/// [locate] and parser functions; agent-specific behaviour (session
/// validation, path construction, line parsing) stays entirely in the
/// agent's module.
class JsonlSessionLoader {
  /// [window] is exposed so tests can inject a small-window instance without
  /// needing a multi-hundred-KiB fixture; production loaders omit it.
  JsonlSessionLoader({JsonlTranscriptWindow? window})
      : _window = window ?? JsonlTranscriptWindow();

  final JsonlTranscriptWindow _window;
  String? _sessionId;
  String? _path;

  /// Whether an older, not-yet-loaded chunk of history exists before the
  /// window [load] has fetched so far — delegates to [JsonlTranscriptWindow.hasOlder].
  bool get hasOlderHistory => _window.hasOlder;

  /// Loads or appends transcript data for [sessionId].
  ///
  /// Resets the window and clears the cached path when [sessionId] differs
  /// from the previous call. Calls [locate] only on the first load for each
  /// new [sessionId] (or after a reset); subsequent polls for the same
  /// session reuse the cached path. Returns null if [locate] returns null
  /// (e.g. the session file does not exist yet).
  Future<NativeTranscript?> load({
    required String sessionId,
    required Future<String?> Function(String id) locate,
    required Future<int> Function(String path) statSize,
    required Future<List<int>> Function(String path, int offset, int? length)
        readRange,
    required List<TranscriptEntry> Function(String input) parseLines,
    required List<TranscriptEntry> Function(String line) parseLine,
  }) async {
    if (_sessionId != sessionId) {
      _sessionId = sessionId;
      _path = null;
      _window.reset();
    }
    final path = _path ?? await locate(sessionId);
    if (path == null) return null;
    _path = path;
    return _window.loadOrAppend(
      statSize: () => statSize(path),
      readRange: (offset, length) => readRange(path, offset, length),
      parseLines: parseLines,
      parseLine: parseLine,
    );
  }

  /// Fetches and prepends the next older bounded chunk — delegates to
  /// [JsonlTranscriptWindow.loadOlder] with the cached path. Returns null
  /// when [hasOlderHistory] is false or no path has been resolved yet.
  Future<NativeTranscript?> loadOlder({
    required Future<List<int>> Function(String path, int offset, int? length)
        readRange,
    required List<TranscriptEntry> Function(String input) parseLines,
  }) {
    final path = _path;
    if (path == null || !_window.hasOlder) return Future.value(null);
    return _window.loadOlder(
      readRange: (offset, length) => readRange(path, offset, length),
      parseLines: parseLines,
    );
  }
}

/// One raw bounded range read, before any record-boundary interpretation is
/// applied — see [JsonlTranscriptWindow._readRaw].
class _RawRead {
  const _RawRead({required this.offset, required this.bytes});

  final int offset;
  final List<int> bytes;
}

/// A resolved, boundary-clean chunk: [clean] begins at a genuine JSONL
/// record boundary at file offset [windowStart] (having discarded any
/// partial/unbounded content found before it — see
/// [JsonlTranscriptWindow._resolveFromConfirmedEdge] and
/// [JsonlTranscriptWindow._resolveFromPendingEdge]).
class _ResolvedChunk {
  const _ResolvedChunk({required this.clean, required this.windowStart});

  final List<int> clean;
  final int windowStart;
}
