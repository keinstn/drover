import 'dart:convert';

import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pure in-memory byte source for [JsonlTranscriptWindow], letting the
/// shared bounded-window/offset/partial-line contract be unit-tested
/// directly — independent of any transport (`CommandRunner`/SSH) or agent
/// (Claude/Copilot) parsing specifics.
class _FakeFile {
  _FakeFile(this.contents);

  String contents;
  final offsets = <int>[];
  final lengths = <int?>[];

  Future<int> statSize() async => utf8.encode(contents).length;

  Future<List<int>> readRange(int offset, int? length) async {
    offsets.add(offset);
    lengths.add(length);
    final bytes = utf8.encode(contents);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
  }
}

/// Treats every non-empty line as its own message, so JSONL/agent-specific
/// parsing never has to be reproduced just to exercise the window's byte
/// bookkeeping.
List<TranscriptEntry> _parseLine(String line) => line.isEmpty
    ? const []
    : [TranscriptMessage(speaker: TranscriptSpeaker.user, text: line)];

List<TranscriptEntry> _parseLines(String input) =>
    const LineSplitter().convert(input).expand(_parseLine).toList();

List<String> _texts(NativeTranscript transcript) =>
    transcript.messages.map((message) => message.text).toList();

void main() {
  group('NativeTranscript.messages', () {
    test('filters to only chat messages, in order', () {
      final transcript = NativeTranscript(const [
        TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'Hi'),
        TranscriptToolUse(name: 'Read', input: {'file_path': '/a.dart'}),
        TranscriptThinking('pondering'),
        TranscriptToolResult('toolu_1'),
        TranscriptMessage(speaker: TranscriptSpeaker.assistant, text: 'Hello'),
      ]);

      expect(transcript.messages.map((message) => message.text), [
        'Hi',
        'Hello',
      ]);
    });
  });

  group('toolUseSummary', () {
    test('truncates a long Bash command to its first line', () {
      final command = 'a' * 110;
      final summary = toolUseSummary('Bash', {
        'command': '$command\nrest of command',
      });

      expect(summary, '${'a' * 100}…');
    });

    test('keeps a short Bash command unchanged', () {
      expect(toolUseSummary('Bash', {'command': 'ls -la'}), 'ls -la');
    });

    test('reads file_path for Read/Edit/Write', () {
      expect(toolUseSummary('Read', {'file_path': '/a.dart'}), '/a.dart');
    });

    test('reads the first question for AskUserQuestion', () {
      final summary = toolUseSummary('AskUserQuestion', {
        'questions': [
          {'question': 'Which approach?'},
          {'question': 'Second question'},
        ],
      });

      expect(summary, 'Which approach?');
    });

    test('falls back to the first string value for unknown tools', () {
      expect(
        toolUseSummary('MysteryTool', {'count': 3, 'label': 'value'}),
        'value',
      );
    });

    test('truncates an unknown tool\'s huge default-branch value', () {
      final label = 'b' * 150;
      final summary = toolUseSummary('MysteryTool', {'label': label});

      expect(summary, '${'b' * 100}…');
    });

    test('collapses a multi-line non-Bash value to its first line', () {
      final summary = toolUseSummary('Grep', {
        'pattern': 'first line\nsecond line',
      });

      expect(summary, 'first line');
    });

    test('returns empty string for wrong-shaped input', () {
      expect(toolUseSummary('Read', {'file_path': 42}), '');
      expect(toolUseSummary('Bash', {}), '');
      expect(
        toolUseSummary('AskUserQuestion', {'questions': 'not a list'}),
        '',
      );
      expect(toolUseSummary('AskUserQuestion', {'questions': []}), '');
      expect(toolUseSummary('Unknown', {}), '');
    });
  });

  group('JsonlTranscriptWindow', () {
    // Uniform-length lines so the byte offset of any line index is exactly
    // predictable (index * lineBytes), letting each test assert precisely on
    // the boundary the window lands on.
    List<String> lines(int count) =>
        List.generate(count, (i) => 'line-${i.toString().padLeft(3, '0')}');

    test(
      'a small file loads fully from offset 0 with no length bound',
      () async {
        final contents = '${lines(3).join('\n')}\n';
        final file = _FakeFile(contents);
        final window = JsonlTranscriptWindow(
          windowBytes: utf8.encode(contents).length,
        );

        final transcript = await window.loadOrAppend(
          statSize: file.statSize,
          readRange: file.readRange,
          parseLines: _parseLines,
          parseLine: _parseLine,
        );

        expect(file.offsets, [0]);
        expect(file.lengths, [null]);
        expect(_texts(transcript), lines(3));
        expect(window.hasOlder, isFalse);
      },
    );

    test('a file larger than the window reads only a bounded tail, discarding '
        'the partial leading record', () async {
      final allLines = lines(10);
      final lineBytes = utf8.encode('${allLines.first}\n').length;
      final contents = '${allLines.join('\n')}\n';
      final totalSize = utf8.encode(contents).length;
      final windowBytes = lineBytes * 4 - (lineBytes ~/ 2);
      final file = _FakeFile(contents);
      final window = JsonlTranscriptWindow(windowBytes: windowBytes);

      final transcript = await window.loadOrAppend(
        statSize: file.statSize,
        readRange: file.readRange,
        parseLines: _parseLines,
        parseLine: _parseLine,
      );

      expect(file.offsets, [totalSize - windowBytes]);
      expect(file.lengths, [windowBytes]);
      final firstIncluded = (file.offsets.single ~/ lineBytes) + 1;
      expect(_texts(transcript), allLines.sublist(firstIncluded));
      expect(window.hasOlder, isTrue);
    });

    test(
      'a later poll transfers only bytes appended since the last read',
      () async {
        final allLines = lines(10);
        final lineBytes = utf8.encode('${allLines.first}\n').length;
        final contents = '${allLines.join('\n')}\n';
        final totalSize = utf8.encode(contents).length;
        final windowBytes = lineBytes * 4 - (lineBytes ~/ 2);
        final file = _FakeFile(contents);
        final window = JsonlTranscriptWindow(windowBytes: windowBytes);

        await window.loadOrAppend(
          statSize: file.statSize,
          readRange: file.readRange,
          parseLines: _parseLines,
          parseLine: _parseLine,
        );
        file.contents += 'line-010\n';
        final transcript = await window.loadOrAppend(
          statSize: file.statSize,
          readRange: file.readRange,
          parseLines: _parseLines,
          parseLine: _parseLine,
        );

        expect(file.offsets, [totalSize - windowBytes, totalSize]);
        expect(file.lengths.last, isNull);
        expect(_texts(transcript).last, 'line-010');
      },
    );

    test('repeated loadOlder calls prepend earlier chunks in order until the '
        'beginning is reached, after which it is a no-op', () async {
      final allLines = lines(10);
      final lineBytes = utf8.encode('${allLines.first}\n').length;
      final contents = '${allLines.join('\n')}\n';
      final windowBytes = lineBytes * 4 - (lineBytes ~/ 2);
      final file = _FakeFile(contents);
      final window = JsonlTranscriptWindow(windowBytes: windowBytes);

      await window.loadOrAppend(
        statSize: file.statSize,
        readRange: file.readRange,
        parseLines: _parseLines,
        parseLine: _parseLine,
      );

      NativeTranscript? last;
      var guard = 0;
      while (window.hasOlder && guard < allLines.length + 2) {
        last = await window.loadOlder(
          readRange: file.readRange,
          parseLines: _parseLines,
        );
        guard++;
      }

      expect(window.hasOlder, isFalse);
      expect(_texts(last!), allLines);

      final callsBeforeNoOp = file.offsets.length;
      final noOp = await window.loadOlder(
        readRange: file.readRange,
        parseLines: _parseLines,
      );
      expect(noOp, isNull);
      expect(file.offsets, hasLength(callsBeforeNoOp));
    });

    test('an oversized newline-terminated final record issues exactly one '
        'bounded range read on initial load, and paging state makes progress '
        '(never re-reads/stalls on the same span)', () async {
      // The whole file is one record far wider than the window, terminated
      // by a trailing newline -- the only newline anywhere in the file.
      const windowBytes = 64;
      final contents = '${'x' * 800}\n';
      final totalSize = utf8.encode(contents).length;
      final file = _FakeFile(contents);
      final window = JsonlTranscriptWindow(windowBytes: windowBytes);

      final transcript = await window.loadOrAppend(
        statSize: file.statSize,
        readRange: file.readRange,
        parseLines: _parseLines,
        parseLine: _parseLine,
      );

      // Exactly one bounded range read, never more than windowBytes.
      expect(file.offsets, [totalSize - windowBytes]);
      expect(file.lengths, [windowBytes]);
      // The oversized record is omitted rather than mis-parsed, but
      // paging state still indicates there's more (unresolved) history to
      // page through.
      expect(_texts(transcript), isEmpty);
      expect(window.hasOlder, isTrue);

      // Paging state makes progress: the next older-page read targets a
      // strictly earlier, non-overlapping span rather than repeating the
      // exact same range (which would stall forever).
      await window.loadOlder(
        readRange: file.readRange,
        parseLines: _parseLines,
      );
      expect(file.offsets, hasLength(2));
      expect(file.offsets[1], lessThan(file.offsets[0]));
      expect(file.lengths[1], lessThanOrEqualTo(windowBytes));
    });

    test('an oversized record between earlier and newer records is traversed '
        'via backward-moving, distinct-offset loadOlder calls, eventually '
        'exposing the earlier complete records', () async {
      const windowBytes = 48;
      final earlier = lines(3);
      final newer = List.generate(
        3,
        (i) => 'new-${i.toString().padLeft(3, '0')}',
      );
      // Much wider than windowBytes, so a single bounded read can never
      // find its own leading boundary.
      final oversized = 'X' * (windowBytes * 6);
      final contents =
          '${earlier.join('\n')}\n$oversized\n${newer.join('\n')}\n';
      final file = _FakeFile(contents);
      final window = JsonlTranscriptWindow(windowBytes: windowBytes);

      final initial = await window.loadOrAppend(
        statSize: file.statSize,
        readRange: file.readRange,
        parseLines: _parseLines,
        parseLine: _parseLine,
      );

      // The tail window lands cleanly on the newer records (the oversized
      // record's own trailing newline is found within the first read),
      // and there's more (the oversized record, then the earlier records)
      // still to page through.
      expect(_texts(initial), newer);
      expect(window.hasOlder, isTrue);
      expect(file.lengths.single, lessThanOrEqualTo(windowBytes));

      NativeTranscript? last;
      var guard = 0;
      // Generously bounded: a handful of hops to traverse the oversized
      // record, plus a couple more to resolve and then parse the earlier
      // records.
      const guardLimit = 30;
      while (window.hasOlder && guard < guardLimit) {
        last = await window.loadOlder(
          readRange: file.readRange,
          parseLines: _parseLines,
        );
        guard++;
      }

      expect(window.hasOlder, isFalse);
      expect(guard, lessThan(guardLimit));
      expect(_texts(last!), [...earlier, ...newer]);

      // Every older-page read (after the initial one) moved strictly
      // backward and none repeated a previous span -- no stalling, no
      // duplicate/overlapping reads.
      final olderOffsets = file.offsets.sublist(1);
      for (var i = 1; i < olderOffsets.length; i++) {
        expect(olderOffsets[i], lessThan(olderOffsets[i - 1]));
      }
      expect(olderOffsets.toSet(), hasLength(olderOffsets.length));
    });

    test('resolving an oversized-record traversal away from offset 0 does '
        'not duplicate or drop the earlier records it prepends', () async {
      // Enough earlier short records that the read which finally finds the
      // oversized record's own leading boundary lands well away from file
      // offset 0, still with more (whole, short) records left before it --
      // exercising `_resolveFromPendingEdge`'s "two directly-observed
      // newlines bound the clean chunk" branch (as opposed to its
      // offset-0 or retroactively-confirmed-boundary branches).
      const windowBytes = 48;
      final earlier = lines(20);
      final newer = List.generate(
        3,
        (i) => 'new-${i.toString().padLeft(3, '0')}',
      );
      final oversized = 'X' * (windowBytes * 6);
      final contents =
          '${earlier.join('\n')}\n$oversized\n${newer.join('\n')}\n';
      final file = _FakeFile(contents);
      final window = JsonlTranscriptWindow(windowBytes: windowBytes);

      final initial = await window.loadOrAppend(
        statSize: file.statSize,
        readRange: file.readRange,
        parseLines: _parseLines,
        parseLine: _parseLine,
      );
      expect(_texts(initial), newer);
      expect(window.hasOlder, isTrue);

      NativeTranscript? last;
      var guard = 0;
      const guardLimit = 30;
      while (window.hasOlder && guard < guardLimit) {
        last = await window.loadOlder(
          readRange: file.readRange,
          parseLines: _parseLines,
        );
        guard++;
      }

      expect(window.hasOlder, isFalse);
      expect(guard, lessThan(guardLimit));
      // The complete, correctly-ordered history, with no records repeated
      // (the bug this guards against re-prepended the same earlier span on
      // the next `loadOlder` call after a pending-edge resolution) and none
      // dropped.
      final texts = _texts(last!);
      expect(texts, [...earlier, ...newer]);
      expect(texts.toSet(), hasLength(texts.length));

      // The pending-edge resolution happens at offset 133, well after the
      // true beginning of the file; it must set the next normal page's
      // boundary to the first clean byte (135), not the trailing newline.
      // Every page stays bounded and moves to a distinct earlier offset.
      expect(file.offsets, contains(133));
      for (var i = 1; i < file.offsets.length; i++) {
        expect(file.offsets[i], lessThan(file.offsets[i - 1]));
      }
      expect(file.offsets.toSet(), hasLength(file.offsets.length));
      for (final length in file.lengths) {
        expect(length, lessThanOrEqualTo(windowBytes));
      }
    });

    test('no initial or older-page range read for a large file ever requests '
        'more than windowBytes', () async {
      const windowBytes = 40;
      final earlier = lines(4);
      final oversized = 'Y' * (windowBytes * 9 + 7);
      final newer = List.generate(
        4,
        (i) => 'new-${i.toString().padLeft(3, '0')}',
      );
      final contents =
          '${earlier.join('\n')}\n$oversized\n${newer.join('\n')}\n';
      final file = _FakeFile(contents);
      final window = JsonlTranscriptWindow(windowBytes: windowBytes);

      await window.loadOrAppend(
        statSize: file.statSize,
        readRange: file.readRange,
        parseLines: _parseLines,
        parseLine: _parseLine,
      );

      var guard = 0;
      while (window.hasOlder && guard < 30) {
        await window.loadOlder(
          readRange: file.readRange,
          parseLines: _parseLines,
        );
        guard++;
      }

      expect(window.hasOlder, isFalse);
      for (final length in file.lengths) {
        expect(length, anyOf(isNull, lessThanOrEqualTo(windowBytes)));
      }
    });

    test(
      'resets and reloads when the file shrinks below what was already read',
      () async {
        final allLines = lines(10);
        final lineBytes = utf8.encode('${allLines.first}\n').length;
        final contents = '${allLines.join('\n')}\n';
        final windowBytes = lineBytes * 4 - (lineBytes ~/ 2);
        final file = _FakeFile(contents);
        final window = JsonlTranscriptWindow(windowBytes: windowBytes);

        await window.loadOrAppend(
          statSize: file.statSize,
          readRange: file.readRange,
          parseLines: _parseLines,
          parseLine: _parseLine,
        );

        file.contents = 'replacement\n';
        final transcript = await window.loadOrAppend(
          statSize: file.statSize,
          readRange: file.readRange,
          parseLines: _parseLines,
          parseLine: _parseLine,
        );

        expect(_texts(transcript), ['replacement']);
        expect(window.hasOlder, isFalse);
      },
    );

    test(
      'loadOlder before any load, or with nothing older, returns null',
      () async {
        final file = _FakeFile('a\nb\n');
        final window = JsonlTranscriptWindow(windowBytes: 4096);

        expect(
          await window.loadOlder(
            readRange: file.readRange,
            parseLines: _parseLines,
          ),
          isNull,
        );

        await window.loadOrAppend(
          statSize: file.statSize,
          readRange: file.readRange,
          parseLines: _parseLines,
          parseLine: _parseLine,
        );

        expect(window.hasOlder, isFalse);
        expect(
          await window.loadOlder(
            readRange: file.readRange,
            parseLines: _parseLines,
          ),
          isNull,
        );
      },
    );
  });
}
