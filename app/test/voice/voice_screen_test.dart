import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/voice/voice_drafts.dart';
import 'package:drover/src/voice/voice_herd.dart';
import 'package:drover/src/voice/voice_screen.dart';
import 'package:drover/src/voice/voice_session.dart';
import 'package:drover/src/voice/voice_tools.dart';
import 'package:drover/src/voice/voice_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeTransport transport;
  late FakeMic mic;
  late FakeSpeaker speaker;

  setUp(() {
    transport = FakeTransport();
    mic = FakeMic();
    speaker = FakeSpeaker();
  });

  Widget app({
    FakeVoiceHerd? herd,
    VoiceInbox? inbox,
    VoiceDrafts? drafts,
    Future<VoiceTransport> Function(String?, String)? connect,
    bool reduceMotion = false,
    ThemeData? theme,
    Locale? locale,
  }) {
    final session = VoiceSession(
      connect: connect ?? (_, _) async => transport,
      mic: mic,
      speaker: speaker,
      herd: herd,
      inbox: inbox,
      drafts: drafts,
      tools: [
        VoiceTool(
          name: 'list_agents',
          description: '',
          parameters: const {},
          run: (_) async => {'agents': []},
        ),
      ],
    );
    final screen = VoiceScreen(session: session);
    return MaterialApp(
      theme: theme ?? droverDarkTheme,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // copyWith, not a bare MediaQueryData: the screen must still lay out
      // against a real screen size.
      // The screen no longer ends the call when it goes, so in these tests
      // nobody would: [_SessionOwner] stands in for the herd screen, which
      // owns the session in the app and disposes it with itself. Without it
      // every test that tears its tree down while live leaves the cap timer
      // pending past the end of the test.
      home: _SessionOwner(
        session: session,
        child: reduceMotion
            ? Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: screen,
                ),
              )
            : screen,
      ),
    );
  }

  final glowKey = find.byKey(const ValueKey('voice_edge_glow'));

  /// The alpha the edge glow's wash actually paints with, off the gradient
  /// it renders — the level is multiplied into the ink, not layered on as an
  /// [Opacity].
  double glowAlpha(WidgetTester tester) =>
      ((tester
                      .widget<DecoratedBox>(
                        find.byKey(const ValueKey('voice_edge_wash')),
                      )
                      .decoration
                  as BoxDecoration)
              .gradient!
              .colors
              .first)
          .a;

  /// How far up the body the glow reaches, in logical pixels.
  double glowReach(WidgetTester tester) => tester.getSize(glowKey).height;

  /// The glow's own pixels: the screen's glow layer is its own repaint
  /// boundary, so this is the light alone, over nothing.
  Future<(ByteData, int, int)> glowPixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: glowKey, matching: find.byType(RepaintBoundary)).first,
    );
    late ByteData data;
    late int width;
    late int height;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      width = image.width;
      height = image.height;
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    return (data, width, height);
  }

  /// Every pixel of the glow layer, as one comparable list.
  Future<Uint8List> glowBytes(WidgetTester tester) async {
    final (data, _, _) = await glowPixels(tester);
    return data.buffer.asUint8List().sublist(0);
  }

  /// The alpha of the screen's very bottom row of glow pixels, left to right.
  Future<List<int>> bottomRow(WidgetTester tester) async {
    final (pixels, width, height) = await glowPixels(tester);
    return [
      for (var x = 0; x < width; x++)
        pixels.getUint8(((height - 1) * width + x) * 4 + 3),
    ];
  }

  /// The alpha of the glow up the left edge (x at 2% of the width), from the
  /// bottom in 5% steps of the height to half way up.
  Future<List<int>> sideColumn(WidgetTester tester) async {
    final (pixels, width, height) = await glowPixels(tester);
    final x = ((width - 1) * 0.02).round();
    return [
      for (var f = 0.0; f <= 0.5; f += 0.05)
        pixels.getUint8(
          ((height - 1 - ((height - 1) * f).round()) * width + x) * 4 + 3,
        ),
    ];
  }

  /// The glow's bottom-left corner pixel — where the wash and the side glow
  /// meet, so the strongest light on the screen — as (r, g, b, a). `rawRgba`
  /// is premultiplied, so the channels are the light's own colour scaled by
  /// its alpha: their *ratios* are the hue, which is what the tint tests
  /// read.
  Future<(int, int, int, int)> cornerPixel(WidgetTester tester) async {
    final (pixels, width, height) = await glowPixels(tester);
    final i = (height - 1) * width * 4;
    return (
      pixels.getUint8(i),
      pixels.getUint8(i + 1),
      pixels.getUint8(i + 2),
      pixels.getUint8(i + 3),
    );
  }

  /// A premultiplied glow pixel as it actually lands on the page: the
  /// screen's own ground showing through whatever alpha the light left. The
  /// page follows the ambient theme now, so the ground does too.
  Color onGround((int, int, int, int) pixel, [ThemeData? theme]) {
    final (r, g, b, a) = pixel;
    final ground = (theme ?? droverDarkTheme).scaffoldBackgroundColor;
    final through = 1 - a / 255;
    int mix(int light, double base) =>
        (light + base * 255 * through).round().clamp(0, 255);
    return Color.fromARGB(
      255,
      mix(r, ground.r),
      mix(g, ground.g),
      mix(b, ground.b),
    );
  }

  /// The brightest ground any text on this screen has to be read against:
  /// the glow's strongest pixel, over the page. Where that pixel is — and
  /// what colour it is — is measured, not assumed, so retuning the shape or
  /// the tint moves it. Returns the ground and that peak alpha.
  Future<(Color, int)> worstGround(
    WidgetTester tester, [
    ThemeData? theme,
  ]) async {
    final (data, _, _) = await glowPixels(tester);
    final bytes = data.buffer.asUint8List();
    var best = 3;
    for (var i = 3; i < bytes.length; i += 4) {
      if (bytes[i] > bytes[best]) best = i;
    }
    return (
      onGround((
        bytes[best - 3],
        bytes[best - 2],
        bytes[best - 1],
        bytes[best],
      ), theme),
      bytes[best],
    );
  }

  /// Points along a bottom row where it gets brighter going *inward* from
  /// the nearer corner — beyond the 2/255 of quantisation noise. The light
  /// is meant to fall from each corner to the wash alone at the centre.
  int risesInward(List<int> row) {
    final mid = row.length ~/ 2;
    var count = 0;
    for (var x = 1; x < row.length; x++) {
      final inward = x <= mid ? row[x] - row[x - 1] : row[x - 1] - row[x];
      if (inward > 2) count++;
    }
    return count;
  }

  /// Interior local maxima along a bottom row — a point brighter than what
  /// sits a readable distance either side of it, which is what an arc, a
  /// dome or a separate dot on the edge looks like in one number. The
  /// 2/255 margin is quantisation noise, not shape.
  int interiorMaxima(List<int> row) {
    final step = (row.length / 40).round();
    var count = 0;
    for (var x = step; x < row.length - step; x++) {
      if (row[x] > row[x - step] + 2 && row[x] > row[x + step] + 2) count++;
    }
    return count;
  }

  /// The status label's paragraph, as laid out.
  RenderParagraph statusParagraph(WidgetTester tester) =>
      tester.renderObject<RenderParagraph>(
        find.byKey(const ValueKey('voice_status')),
      );

  /// Where the status label's first glyph is actually painted. With
  /// [TextAlign.end] this moves with the string's width; if the label is
  /// only shrink-wrapped and pushed right by a [Spacer] it never moves.
  double statusGlyphLeft(WidgetTester tester) {
    final para = statusParagraph(tester);
    final dx = para
        .getOffsetForCaret(const TextPosition(offset: 0), Rect.zero)
        .dx;
    return para.localToGlobal(Offset(dx, 0)).dx;
  }

  /// The right edge of the space the label is laid out in.
  double statusRight(WidgetTester tester) {
    final para = statusParagraph(tester);
    return para.localToGlobal(Offset(para.size.width, 0)).dx;
  }

  /// Lays the screen out on a phone-width surface, so the header's margins
  /// are the ones the design specifies.
  Future<void> onPhone(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// Feeds [times] mic frames at [amplitude] of full scale and lets each one
  /// reach the level notifier.
  Future<void> pushMic(
    WidgetTester tester,
    double amplitude, {
    int times = 4,
  }) async {
    for (var i = 0; i < times; i++) {
      mic.frames.add(pcm16Frame(amplitude));
      await tester.pump();
      await tester.pump();
    }
  }

  /// Hands the floor to the assistant and turns its voice up: ten seconds of
  /// model audio, so `speaking` stays true for the rest of the test, then
  /// [times] speaker level windows at [value] — the output path owns the
  /// level while the model plays, so this is the only way the glow gets loud
  /// with the assistant talking. Ends on a pump long enough for the tint to
  /// finish following the flip; the level pumps carry no time of their own.
  Future<void> pushSpeaker(
    WidgetTester tester,
    double value, {
    int times = 40,
  }) async {
    transport.push(audioChunk(bytes: 48000 * 10));
    await tester.pump();
    for (var i = 0; i < times; i++) {
      speaker.levels.add(value);
      await tester.pump();
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('starts on open and shows the greeting until something is said', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Listening'), findsOneWidget);
    expect(find.text("Let's talk about your agents"), findsOneWidget);
    expect(find.textContaining('Ask about your agents'), findsOneWidget);
    expect(find.byTooltip('End'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'the greeting scrolls instead of overflowing at a large text size',
    (tester) async {
      // iPhone SE at an accessibility text size: the hint alone outgrows the
      // header-to-controls region, so without a scroll view it overflows.
      await tester.binding.setSurfaceSize(const Size(375, 667));
      tester.platformDispatcher.textScaleFactorTestValue = 3.0;
      addTearDown(() {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        return tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(app());
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Ask about your agents'), findsOneWidget);
      // The hint's text box really is taller than the region it sits in.
      final hint = tester.getRect(find.textContaining('Ask about your agents'));
      final region = tester.getRect(find.byType(SingleChildScrollView).first);
      expect(hint.height, greaterThan(region.height));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('renders assistant text after a completed turn', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    transport.push(
      LiveServerContent(
        outputTranscription: const Transcription(text: 'One agent is blocked.'),
        turnComplete: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text("Let's talk about your agents"), findsNothing);
    expect(find.textContaining('Ask about your agents'), findsNothing);
    expect(find.text('One agent is blocked.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders the resumed notice after a reconnect', (tester) async {
    final connector = FakeConnector();
    await tester.pumpWidget(app(connect: connector.call));
    await tester.pump();

    connector.last.pushResumption('h1');
    await tester.pump();
    await connector.transports.first.server.close();
    await tester.pump();
    await tester.pump();

    expect(find.text('Reconnected, continuing'), findsOneWidget);
    expect(find.text('Session ended'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders a tool line for a tool call', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    transport.push(
      LiveServerToolCall(
        functionCalls: const [FunctionCall('list_agents', {}, id: 'c1')],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Called list_agents'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tapping End renders the ended status and offers Restart', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();

    expect(find.text('Ended'), findsOneWidget);
    expect(find.text('Session ended'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(transport.closeCalls, 1);
    final action = find.byKey(const ValueKey('voice_action_button'));
    expect(action, findsOneWidget);
    expect(
      find.descendant(of: action, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
    expect(find.byTooltip('End'), findsNothing);
    expect(find.byKey(const ValueKey('voice_close_button')), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the usage readout is rendered when the session ends', (
    tester,
  ) async {
    // The `usageMetadata` of one real turn, from the capture the transport
    // tests replay; here it stands for what the socket counted.
    final turn =
        (jsonDecode(File('test/voice/live_frames.json').readAsStringSync())
                as Map<String, Object?>)['turnComplete']!
            as Map<String, Object?>;
    transport.usage.add(turn['usageMetadata']);
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();

    // Two halves of the one line, so a clock that ticked mid-test cannot
    // make this flaky.
    expect(find.textContaining('usage · 1 turn · '), findsOneWidget);
    expect(
      find.textContaining(
        ' · prompt 982 (TEXT 742, AUDIO 201) · response 20 (AUDIO 20)',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('Restart reconnects and puts the status back to Listening', (
    tester,
  ) async {
    final connector = FakeConnector();
    await tester.pumpWidget(app(connect: connector.call));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();
    expect(find.text('Session ended'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pump();
    await tester.pump();

    expect(connector.transports, hasLength(2));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('voice_status'))).data,
      'Listening',
    );
    // The log is history now, so the previous session's end stays in it.
    expect(find.text('Session ended'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a long connect error gets the header\'s full width', (
    tester,
  ) async {
    await onPhone(tester);
    await tester.pumpWidget(
      app(
        connect: (_, _) async =>
            throw StateError('failed to connect ${'x' * 200}'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    final status = find.byKey(const ValueKey('voice_status'));
    expect(status, findsOneWidget);
    expect(tester.widget<Text>(status).data, contains('xxx'));
    // Text.data and takeException both ignore truncation, so assert the
    // label is actually painted across the header: it runs to the 20pt
    // right margin, and gets everything the back button leaves rather than
    // half of it (~143pt when a Spacer splits the row 50/50).
    expect(statusRight(tester), closeTo(390 - 20, 0.5));
    expect(statusParagraph(tester).size.width, greaterThan(250));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  for (final (locale, expected) in [
    (const Locale('en'), 'Error: You are out of voice credits.'),
    (const Locale('ja'), 'エラー: ボイスクレジットがありません。'),
  ]) {
    testWidgets('an empty balance is rendered in ${locale.languageCode}', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          locale: locale,
          connect: (_, _) async => throw const VoiceOutOfCredits(),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The refused mint is all the app can ever know about the balance, so
      // what it puts on screen has to be its own sentence — not a stringified
      // exception, and not nothing.
      expect(find.text(expected), findsWidgets);
    });
  }

  testWidgets('an errored session says so in the log, not the greeting', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(connect: (_, _) async => throw StateError('no host')),
    );
    await tester.pump();
    await tester.pump();

    // The greeting invites the user to talk; there is nothing listening.
    expect(find.text("Let's talk about your agents"), findsNothing);
    expect(find.textContaining('Ask about your agents'), findsNothing);
    // And the error is in the body, where it can be read in full.
    final body = find.byKey(const ValueKey('voice_error_body'));
    expect(body, findsOneWidget);
    expect(tester.widget<Text>(body).data, contains('no host'));
    expect(
      find.descendant(of: find.byType(ListView), matching: body),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a long error reads in full in the body, not clipped', (
    tester,
  ) async {
    await onPhone(tester);
    await tester.pumpWidget(
      app(
        connect: (_, _) async =>
            throw StateError('failed to connect ${'x' * 200}'),
      ),
    );
    await tester.pump();
    await tester.pump();

    final para = tester.renderObject<RenderParagraph>(
      find.byKey(const ValueKey('voice_error_body')),
    );
    // Laid out, not merely present: count the lines the glyphs actually
    // sit on. The header clamps to two and ellipsises the rest, which is
    // the whole reason the body carries it as well.
    final boxes = para.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: para.text.toPlainText().length,
      ),
    );
    expect(boxes.map((b) => b.top).toSet().length, greaterThan(2));
    expect(para.didExceedMaxLines, isFalse);
    expect(statusParagraph(tester).maxLines, 2);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the status label is end-aligned, not parked mid-header', (
    tester,
  ) async {
    await onPhone(tester);
    await tester.pumpWidget(app());
    await tester.pump();
    final shortLeft = statusGlyphLeft(tester);
    final shortRight = statusRight(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await tester.pumpWidget(
      app(
        connect: (_, _) async =>
            throw StateError('failed to connect ${'x' * 200}'),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The short label starts much further right than the long one, and both
    // end at the same right margin: the label is aligned to the end, not
    // pinned to a fixed half-width slot that starts every string at one x.
    expect(statusGlyphLeft(tester), lessThan(shortLeft - 100));
    expect(statusRight(tester), closeTo(shortRight, 0.5));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('offers a labelled Back while live', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Listening'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('several pending cards scroll inside their cap', (tester) async {
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      drafts.addLaunch(
        kind: 'codex',
        cwd: '/home/me/proj$i',
        brief:
            'Add a retry to the webhook client. Back off exponentially and '
            'cap it at five attempts. Keep the change small and add a test.',
      );
    }
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    final pinned = find.byKey(const ValueKey('voice_pending_drafts'));
    // Capped: four cards never eat the screen, so the transcript keeps the
    // larger half of the region.
    expect(tester.getSize(pinned).height, lessThanOrEqualTo(300));
    // The newest card's button is the one on screen, without scrolling.
    final last = find.byKey(const ValueKey('voice_launch_d4'));
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(600));
    // The older ones are a scroll away inside the pinned section, not lost.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('voice_launch_d1')),
      -120,
      scrollable: find.descendant(
        of: pinned,
        matching: find.byType(Scrollable),
      ),
    );
    final first = find.byKey(const ValueKey('voice_launch_d1'));
    expect(first, findsOneWidget);
    expect(tester.getRect(first).bottom, lessThanOrEqualTo(600));
    // And the transcript is still there, still scrollable.
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the log is the screen: rows render with no toggle to tap', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();
    transport.push(
      LiveServerContent(
        inputTranscription: const Transcription(
          text: 'Which agent is waiting?',
          finished: true,
        ),
      ),
    );
    transport.push(
      LiveServerContent(
        outputTranscription: const Transcription(text: 'One agent is blocked.'),
        turnComplete: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('Which agent is waiting?'), findsOneWidget);
    expect(find.text('One agent is blocked.'), findsOneWidget);
    // The status label moved to the header; it is on screen alongside the log.
    expect(find.byKey(const ValueKey('voice_status')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders why the session ended when the cap runs out', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.pump(kVoiceSessionCap + const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Session time limit reached'), findsOneWidget);
    expect(find.text('Ended'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('renders an announced event as a muted line', (tester) async {
    final herd = FakeVoiceHerd();
    final inbox = VoiceInbox();
    await tester.pumpWidget(app(herd: herd, inbox: inbox));
    await tester.pump();

    inbox.add(AgentEvent(AgentEventKind.finished, fakeAgent(kind: 'claude')));
    await tester.pump();
    await tester.pump();

    expect(find.text('claude finished'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    inbox.dispose();
  });

  testWidgets('a pending draft renders with Send; tapping sends it', (
    tester,
  ) async {
    final herd = FakeVoiceHerd();
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: herd, drafts: drafts));
    await tester.pump();

    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting to send to claude'), findsOneWidget);
    expect(find.text('add tests too'), findsOneWidget);
    final send = find.byKey(const ValueKey('voice_draft_send_d1'));
    expect(send, findsOneWidget);

    await tester.tap(send);
    await tester.pump();
    await tester.pump();

    expect(herd.sent.single.$2, 'add tests too');
    expect(send, findsNothing);
    expect(find.text('Waiting to send to claude'), findsNothing);
    expect(find.text('Sent to claude'), findsOneWidget);
    expect(find.text('add tests too'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a launch draft renders the brief; tapping Launch starts it', (
    tester,
  ) async {
    final herd = FakeVoiceHerd();
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: herd, drafts: drafts));
    await tester.pump();

    drafts.addLaunch(
      kind: 'codex',
      cwd: '/home/me/billing-api',
      brief: 'Add a retry to the webhook client. Keep it small.',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting to start Codex in billing-api'), findsOneWidget);
    expect(
      find.text('Add a retry to the webhook client. Keep it small.'),
      findsOneWidget,
    );
    final launch = find.byKey(const ValueKey('voice_launch_d1'));
    expect(launch, findsOneWidget);

    // The launch takes a while; the button must not start a second agent.
    herd.launchGate = Completer<void>();
    await tester.tap(launch);
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(launch).onPressed, isNull);
    await tester.tap(launch, warnIfMissed: false);
    await tester.pump();

    herd.launchGate!.complete();
    await tester.pump();
    await tester.pump();

    expect(herd.launched.single, (
      'codex',
      '/home/me/billing-api',
      'Add a retry to the webhook client. Keep it small.',
    ));
    expect(launch, findsNothing);
    expect(find.text('Started Codex in billing-api'), findsOneWidget);
    expect(find.text('Codex in billing-api'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a pending draft stays reachable once the log scrolls past it', (
    tester,
  ) async {
    final herd = FakeVoiceHerd();
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: herd, drafts: drafts));
    await tester.pump();

    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    await tester.pump();
    // PR #229's case: the model narrates on after proposing, and the log
    // grows well past a screenful. The Send button is the ground truth, so
    // it has to survive that.
    for (var i = 0; i < 12; i++) {
      transport.push(
        LiveServerContent(
          outputTranscription: Transcription(text: 'Still talking, line $i.'),
          turnComplete: true,
        ),
      );
      await tester.pump();
    }
    await tester.pump();

    final send = find.byKey(const ValueKey('voice_draft_send_d1'));
    expect(send, findsOneWidget);
    // On screen, not merely in the tree.
    final rect = tester.getRect(send);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(600));
    // And actually hittable: the send is the assertion, since an off-screen
    // tap only warns.
    await tester.tap(send);
    await tester.pump();
    await tester.pump();
    expect(herd.sent.single.$2, 'add tests too');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a card taller than the cap still shows its button', (
    tester,
  ) async {
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
    await tester.pump();
    drafts.addLaunch(
      kind: 'codex',
      cwd: '/home/me/proj',
      brief: List.filled(60, 'a very long brief sentence.').join(' '),
    );
    await tester.pump();
    await tester.pump();
    // Scrolled from the top, a brief this long would push its own Launch
    // button out of the capped viewport; the pinned section is reversed so
    // the button edge is the one that stays.
    final launch = find.byKey(const ValueKey('voice_launch_d1'));
    expect(tester.getRect(launch).bottom, lessThanOrEqualTo(600));
    expect(tester.getRect(launch).top, greaterThanOrEqualTo(0));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a pending draft renders once: pinned, not also in the log', (
    tester,
  ) async {
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
    await tester.pump();

    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    await tester.pump();
    await tester.pump();

    // Exactly one card, and it is the pinned one.
    expect(find.text('add tests too'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice_draft_send_d1')), findsOneWidget);
    final pinned = find.byKey(const ValueKey('voice_pending_drafts'));
    expect(
      find.descendant(of: pinned, matching: find.text('add tests too')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('add tests too'),
      ),
      findsNothing,
    );
    // Pinned below the log, above the controls.
    expect(
      tester.getRect(pinned).top,
      greaterThanOrEqualTo(tester.getRect(find.byType(ListView)).bottom),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a resolved draft leaves the pinned section for the log', (
    tester,
  ) async {
    final herd = FakeVoiceHerd();
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: herd, drafts: drafts));
    await tester.pump();

    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('voice_draft_send_d1')));
    await tester.pump();
    await tester.pump();

    expect(herd.sent.single.$2, 'add tests too');
    // Nothing left to pin...
    expect(find.byKey(const ValueKey('voice_pending_drafts')), findsNothing);
    // ...and the card is back in the log, at its chronological place.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('add tests too'),
      ),
      findsOneWidget,
    );
    expect(find.text('Sent to claude'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('ending with a pending draft shows the unsent notice', (
    tester,
  ) async {
    final drafts = VoiceDrafts();
    await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
    await tester.pump();
    drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
    drafts.addLaunch(kind: 'codex', cwd: '/tmp/proj', brief: 'add retries');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice_action_button')));
    await tester.pumpAndSettle();

    // Worded for either card: a launch draft's button says Launch, not Send.
    expect(
      find.text(
        'A draft is still pending — the button on its card still works',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_draft_send_d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice_launch_d2')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the page follows the ambient theme', (tester) async {
    // Replaces the pair that pinned the forced dark ground and the status-bar
    // flip. The screen no longer forces `droverDarkTheme` — the glow carries
    // the speaker's colour now, and chroma is something a white page *can*
    // gain — so the only thing left to pin is that the page is the theme's.
    // The overlay style went with it: the host route's AppBar publishes the
    // one that matches whichever theme is on.
    for (final theme in [droverLightTheme, droverDarkTheme]) {
      transport = FakeTransport();
      await tester.pumpWidget(app(theme: theme));
      await tester.pump();

      // What the page is actually filled with...
      final page = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(Scaffold),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(page.color, theme.scaffoldBackgroundColor);
      // ...and what is painted on it: the screen's muted ink follows the
      // ambient brightness, which it cannot if a Theme is being forced. The
      // literals are the screen's own per-theme inks, not the theme's
      // tertiary (3.6:1 on the light page at label size).
      expect(
        statusParagraph(tester).text.style?.color,
        theme == droverLightTheme
            ? const Color(0xFF4F4F55)
            : const Color(0xFFDBDAE1),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  group('edge glow', () {
    testWidgets('brightens and reaches further with the level, then back', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final restAlpha = glowAlpha(tester);
      final restReach = glowReach(tester);

      // A resting presence, not an invisible one.
      expect(restAlpha, greaterThan(0));
      expect(restReach, greaterThan(0));

      await pushMic(tester, 0.3);
      expect(glowAlpha(tester), greaterThan(restAlpha));
      expect(glowReach(tester), greaterThan(restReach));

      await pushMic(tester, 0, times: 30);
      expect(glowAlpha(tester), closeTo(restAlpha, 0.002));
      expect(glowReach(tester), closeTo(restReach, 2));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('holds its resting strength and reach at level 0', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final rest = glowAlpha(tester);
      final restReach = glowReach(tester);

      // Nothing but the level drives it, so time alone changes nothing.
      await tester.pump(const Duration(seconds: 3));
      expect(glowAlpha(tester), rest);
      expect(glowReach(tester), restReach);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('stays fixed under reduce motion, however loud it gets', (
      tester,
    ) async {
      await tester.pumpWidget(app(reduceMotion: true));
      await tester.pump();
      final restAlpha = glowAlpha(tester);
      final restReach = glowReach(tester);
      final rest = await glowBytes(tester);

      // The same picture three seconds later, pixel for pixel.
      await tester.pump(const Duration(seconds: 3));
      expect(await glowBytes(tester), rest);

      await pushMic(tester, 0.3);
      expect(glowAlpha(tester), restAlpha);
      expect(glowReach(tester), restReach);
      expect(await glowBytes(tester), rest);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
      'under reduce motion the light still changes hands, in a step',
      (tester) async {
        // Colour is state, not motion: with animations off the glow stays at
        // rest strength and never tweens, but it is still the floor-holder's
        // colour, so a speaker flip is an instant hue change — not invariance.
        await tester.pumpWidget(app(reduceMotion: true));
        await tester.pump();
        final (r0, _, b0, _) = await cornerPixel(tester);
        expect(b0, greaterThan(r0), reason: 'cool while listening');

        await pushSpeaker(tester, 1.0);
        final (r1, _, b1, _) = await cornerPixel(tester);
        expect(r1, greaterThan(b1), reason: 'warm while the model talks');

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );

    testWidgets('washes the whole bottom edge on a wide window', (
      tester,
    ) async {
      // 800x600: much wider than the glow box is tall, which is where a
      // radial wash pulls off the sides and breaks into three blobs.
      await tester.pumpWidget(app());
      await tester.pump();

      final (pixels, width, height) = await glowPixels(tester);
      int alphaAt(double fraction) {
        final x = ((width - 1) * fraction).round();
        return pixels.getUint8(((height - 1) * width + x) * 4 + 3);
      }

      // The light reaches the sides, and along the edge it is flat between
      // the corner hotspots — not a dome with a gap either side of it.
      for (final f in [0.25, 0.5, 0.75, 0.05, 0.95]) {
        expect(alphaAt(f), greaterThan(10), reason: 'bare at x=$f of width');
      }
      final middles = [alphaAt(0.25), alphaAt(0.5), alphaAt(0.75)];
      expect(
        middles.reduce((a, b) => a > b ? a : b) -
            middles.reduce((a, b) => a < b ? a : b),
        lessThanOrEqualTo(2),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('the bottom edge stays one body at every size and level', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // One session throughout: a second one would reuse the transport the
      // first closed and never go live, so the level would stay at 0.
      await tester.pumpWidget(app());
      await tester.pump();
      for (final size in const [
        Size(390, 844),
        Size(844, 390),
        Size(1280, 800),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pump();
        for (final loud in const [false, true]) {
          if (loud) await pushMic(tester, 0.9, times: 20);

          final row = await bottomRow(tester);
          final low = row.reduce(min);
          final mid = row[row.length ~/ 2];
          final wash = (glowAlpha(tester) * 255).round();
          final rises = risesInward(row);
          final maxima = interiorMaxima(row);
          debugPrint(
            'bottom row $size loud=$loud: corners=${row.first}/${row.last} '
            'mid=$mid min=$low wash=$wash rises=$rises maxima=$maxima '
            'reach=${glowReach(tester)} side column=${await sideColumn(tester)}',
          );
          // Lit right across; brightest at the corners, where the wash and
          // the side glow meet; the wash alone at the centre; and falling
          // from each corner to that centre without a bump on the way — so
          // never below the wash, never rising going inward, and no local
          // peak anywhere: no readable arc, dome or separate dot.
          expect(low, greaterThan(10), reason: 'bare edge at $size loud=$loud');
          expect(
            low,
            greaterThanOrEqualTo(wash - 2),
            reason: 'dips below the wash at $size loud=$loud',
          );
          expect(mid, closeTo(wash, 2), reason: 'centre at $size loud=$loud');
          expect(row.first, greaterThanOrEqualTo(mid));
          expect(row.last, greaterThanOrEqualTo(mid));
          expect(rises, 0, reason: 'rises inward at $size loud=$loud');
          expect(maxima, 0, reason: 'a shape on the edge at $size loud=$loud');

          if (loud) await pushMic(tester, 0, times: 40);
        }
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('the side glow is an edge: low on the side, not a band', (
      tester,
    ) async {
      await onPhone(tester);
      await tester.pumpWidget(app());
      await tester.pump();
      // Loud: the side glow is at its brightest, and reaches highest.
      await pushMic(tester, 0.99, times: 40);

      final (pixels, width, height) = await glowPixels(tester);
      final reach = glowReach(tester);
      final edge = glowAlpha(tester) * 255;

      /// Alpha over the wash — a straight ramp from the edge's alpha to
      /// nothing at the wash box's top — at [fx] of the width and [fy] of
      /// the height up from the bottom.
      int extra(double fx, double fy) {
        final x = ((width - 1) * fx).round();
        final y = height - 1 - ((height - 1) * fy).round();
        final wash = y < height - reach
            ? 0.0
            : edge * (1 - (height - 0.5 - y) / reach);
        return pixels.getUint8((y * width + x) * 4 + 3) - wash.round();
      }

      debugPrint(
        'side glow edge: 10%=${extra(0.02, 0.1)} 40%=${extra(0.02, 0.4)} '
        'inboard: 10%=${extra(0.4, 0.1)} 40%=${extra(0.4, 0.4)}',
      );
      // Along the side edge the light is clearly there low down and gone by
      // 40% up; a third of the way in from the edge, at the same heights,
      // there is nothing but the wash — an edge, not a band across.
      expect(extra(0.02, 0.1), greaterThanOrEqualTo(10));
      expect(extra(0.02, 0.4), lessThanOrEqualTo(2));
      expect(extra(0.4, 0.1), lessThanOrEqualTo(2));
      expect(extra(0.4, 0.4), lessThanOrEqualTo(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('at rest the light is the listening one, only fainter', (
      tester,
    ) async {
      await onPhone(tester);
      await tester.pumpWidget(app());
      await tester.pump();

      // Silence is not a third, neutral state: nobody talking means the
      // assistant is listening, so a quiet room is the cool light — faint.
      // (It used to be the page's own neutral ink; that is the change.)
      final (r, g, b, a) = await cornerPixel(tester);
      debugPrint('rest corner rgba=$r,$g,$b,$a');
      expect(a, greaterThan(20), reason: 'no light to read a colour off');
      expect(b - r, greaterThan(15), reason: 'not cool at rest: $r,$g,$b');

      await pushMic(tester, 0.99, times: 40);
      final (_, _, _, loud) = await cornerPixel(tester);
      expect(a, lessThan(loud), reason: 'rest is not the fainter light');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a loud user turn turns the light cool', (tester) async {
      await onPhone(tester);
      await tester.pumpWidget(app());
      await tester.pump();
      await pushMic(tester, 0.99, times: 40);

      final (r, g, b, a) = await cornerPixel(tester);
      debugPrint('listening corner rgba=$r,$g,$b,$a');
      expect(b - r, greaterThan(15), reason: 'not cool: $r,$g,$b');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a loud assistant turn turns the light warm', (tester) async {
      await onPhone(tester);
      await tester.pumpWidget(app());
      await tester.pump();
      await pushSpeaker(tester, 1);

      final (r, g, b, a) = await cornerPixel(tester);
      debugPrint('speaking corner rgba=$r,$g,$b,$a');
      expect(r - b, greaterThan(15), reason: 'not warm: $r,$g,$b');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('neither speaker is the brighter light, on either theme', (
      tester,
    ) async {
      // Was "the assistant is never dimmer than silence", which compared a
      // loud warm turn against the *resting* glow. That no longer
      // discriminates: rest is the same cool ink at a third of the alpha, so
      // the alpha gap alone carries it whatever the warm ink is. And it does
      // not generalise — on the light theme a loud glow is *darker* than a
      // quiet one, because the white page loses luminance instead of gaining
      // it. What the two inks actually have to satisfy is the same thing on
      // both themes: at one level they are the same light, differing only in
      // hue. So compare them at the same level.
      for (final (name, theme) in [
        ('dark', droverDarkTheme),
        ('light', droverLightTheme),
      ]) {
        transport = FakeTransport();
        await onPhone(tester);
        await tester.pumpWidget(app(theme: theme));
        await tester.pump();

        await pushMic(tester, 0.99, times: 40);
        final cool = (await worstGround(tester, theme)).$1.computeLuminance();
        await pushSpeaker(tester, 1);
        final warm = (await worstGround(tester, theme)).$1.computeLuminance();

        debugPrint('$name loud luminance: cool=$cool warm=$warm');
        // 5% of the cool one: the inks are picked at an identical HSL S and
        // L per theme, which lands them inside 1.5%. A warm ink dark enough
        // to read as the room going out when the assistant starts talking —
        // the failure this has always guarded — is far outside it.
        expect((warm - cool).abs() / cool, lessThan(0.05));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    });

    testWidgets('the wash is the strengthened one', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final rest = glowAlpha(tester);
      await pushMic(tester, 0.99, times: 40);
      final loud = glowAlpha(tester);
      debugPrint('wash alpha: rest=$rest loud=$loud');

      // The first pass painted 0.22 * 0.45 = 0.099 at rest and 0.22 loud,
      // and read as weak on a device. 1.4x the wash and the side glow, and a
      // higher resting presence: 0.31 * 0.52 = 0.161 and 0.31.
      expect(rest, greaterThan(0.15));
      expect(loud, greaterThan(0.30));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('on the light theme the wash is a tint, not a grey smudge', (
      tester,
    ) async {
      await onPhone(tester);
      await tester.pumpWidget(app(theme: droverLightTheme));
      await tester.pump();
      final page = droverLightTheme.scaffoldBackgroundColor;
      int delta(Color c) => [
        ((c.r - page.r) * 255).abs().round(),
        ((c.g - page.g) * 255).abs().round(),
        ((c.b - page.b) * 255).abs().round(),
      ].reduce(max);

      await pushMic(tester, 0.99, times: 40);
      final cool = onGround(await cornerPixel(tester), droverLightTheme);
      await pushSpeaker(tester, 1);
      final warm = onGround(await cornerPixel(tester), droverLightTheme);
      debugPrint(
        'light corner on page: cool=#${cool.toARGB32().toRadixString(16)} '
        'delta=${delta(cool)} warm=#${warm.toARGB32().toRadixString(16)} '
        'delta=${delta(warm)}',
      );

      // A hue on the page, read after compositing: the white page cannot
      // gain luminance, so the tint is the only thing that separates this
      // from the achromatic smudge that used to keep the screen dark.
      expect((cool.b - cool.r) * 255, greaterThan(15), reason: 'not cool');
      expect((warm.r - warm.b) * 255, greaterThan(15), reason: 'not warm');
      // And enough of it to see. 70/255 is ~27% of the range; it is also
      // what separates the light ink pair from the dark one — the dark
      // theme's pale #8FC0F2/#F2A98F composited onto white only reach 46,
      // which is the faint paper-fold reading this screen had to escape.
      expect(delta(cool), greaterThanOrEqualTo(70));
      expect(delta(warm), greaterThanOrEqualTo(70));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('every text clears 4.5:1 over the brightest glow there is', (
      tester,
    ) async {
      // Both themes, three states each. There is no synthetic "neutral
      // ceiling" any more: the glow is only ever painted in a speaker ink,
      // so every ground it can make is one of these six, read off the render.
      for (final (name, theme) in [
        ('dark', droverDarkTheme),
        ('light', droverLightTheme),
      ]) {
        transport = FakeTransport();
        final drafts = VoiceDrafts();
        await tester.pumpWidget(
          app(herd: FakeVoiceHerd(), drafts: drafts, theme: theme),
        );
        await tester.pump();
        transport.push(
          LiveServerToolCall(
            functionCalls: const [FunctionCall('list_agents', {}, id: 'c1')],
          ),
        );
        transport.push(
          LiveServerContent(
            outputTranscription: const Transcription(
              text: 'One agent is blocked.',
            ),
            turnComplete: true,
          ),
        );
        drafts.add(fakeAgent(kind: 'claude'), 'add tests too');
        await tester.pump();
        await tester.pump();
        // Read off what is painted, not off the source: both the ink and the
        // ground have to come from the render for this to pin anything.
        Color colorOf(Finder f) =>
            tester.renderObject<RenderParagraph>(f).text.style!.color!;
        final texts = {
          'tool line': colorOf(find.text('Called list_agents')),
          'draft card header': colorOf(find.text('Waiting to send to claude')),
          'draft card body': colorOf(find.text('add tests too')),
          // Bubbles have an opaque fill, so their text never meets the glow;
          // the header label has none and is the smallest text on the page.
          'status label': colorOf(find.byKey(const ValueKey('voice_status'))),
        };
        var worstRatio = double.infinity;
        var worstCase = '';
        void clears(String state, Color ground) {
          debugPrint(
            '$name $state ground=#${ground.toARGB32().toRadixString(16)}',
          );
          for (final MapEntry(key: what, value: color) in texts.entries) {
            final ratio = contrastRatio(color, ground);
            if (ratio < worstRatio) {
              worstRatio = ratio;
              worstCase =
                  '$what #${color.toARGB32().toRadixString(16)} over the '
                  '$state ground #${ground.toARGB32().toRadixString(16)} = '
                  '${ratio.toStringAsFixed(2)}:1';
            }
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason:
                  '$name: $what at ${color.toARGB32().toRadixString(16)} '
                  'over the $state glow',
            );
          }
        }

        // Rest is the listening ink at the resting alpha, not a neutral.
        final (resting, restPeak) = await worstGround(tester, theme);
        clears('resting', resting);

        // Full level, and it stays there: the level only moves when a frame
        // lands, so each scan is one loudness throughout.
        await pushMic(tester, 0.99, times: 40);
        final (cool, peak) = await worstGround(tester, theme);
        clears('loud listening', cool);

        await pushSpeaker(tester, 1);
        final (warm, _) = await worstGround(tester, theme);
        clears('loud speaking', warm);

        debugPrint(
          '$name peak alpha rest=$restPeak/255 loud=$peak/255 — '
          'worst case: $worstCase',
        );

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    });
  });

  group('continuing a conversation', () {
    /// The screen behind a pushed [VoiceScreen], so popping it exercises
    /// `State.dispose` for real — and pushing again re-enters the SAME
    /// session, which is what the herd screen does once it retains one.
    Widget host(VoiceSession session) => MaterialApp(
      // The transcript renders here, and its rows read [DroverColors] off
      // the theme.
      theme: droverDarkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VoiceScreen(session: session),
            ),
          ),
          child: const Text('voice'),
        ),
      ),
    );

    testWidgets('popping the screen leaves the call listening', (tester) async {
      // A fresh transport per connect, so a reconnect would be visible as a
      // second one — there should be none.
      final connector = FakeConnector();
      final session = VoiceSession(
        connect: connector.call,
        mic: mic,
        speaker: speaker,
        tools: const [],
      );
      await tester.pumpWidget(host(session));
      await tester.tap(find.text('voice'));
      await tester.pumpAndSettle();

      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pumpAndSettle();

      // Nothing was released: the user is on another drover screen, not out
      // of the app, and the call is still listening there.
      expect(mic.stopCalls, 0);
      expect(mic.disposeCalls, 0);
      expect(speaker.disposeCalls, 0);
      expect(session.status, VoiceSessionStatus.live);

      await tester.tap(find.text('voice'));
      await tester.pumpAndSettle();

      // Re-entering finds the same call on the same socket. Nothing was torn
      // down, so there is nothing to reconnect and nothing to log.
      expect(connector.transports, hasLength(1));
      expect(find.text('Reconnected, continuing'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('voice_status'))).data,
        'Listening',
      );

      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.pump();
    });

    testWidgets('coming back to the foreground continues the call', (
      tester,
    ) async {
      final connector = FakeConnector();
      await tester.pumpWidget(app(connect: connector.call));
      await tester.pump();
      connector.last.pushResumption('h1');
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Let `background()` finish before coming back: here the two land in
      // one synchronous sequence, where a real return is minutes later, and
      // a `start()` on a session still reading as live is a no-op by design.
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(find.text('App went to the background'), findsOneWidget);
      expect(find.text('Reconnected, continuing'), findsOneWidget);
      expect(connector.handles, [null, 'h1']);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('voice_status'))).data,
        'Listening',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('coming back after End starts nothing', (tester) async {
      final connector = FakeConnector();
      await tester.pumpWidget(app(connect: connector.call));
      await tester.pump();
      // A handle in hand, so what stops the continuation is the End alone.
      connector.last.pushResumption('h1');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('voice_action_button')));
      await tester.pumpAndSettle();
      expect(find.text('Session ended'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(connector.transports, hasLength(1));
      expect(find.text('Reconnected, continuing'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('voice_status'))).data,
        'Ended',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('app lifecycle', () {
    testWidgets('paused ends the live session, rendering why it ended', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();

      // Drives the real state machine end to end (resumed -> inactive ->
      // hidden -> paused) rather than jumping straight there:
      // `AppLifecycleListener` asserts on invalid transitions.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      // Flutter suppresses frame production while paused — same as a real OS
      // backgrounding the app — so `background()`'s rebuild is pending but
      // unpainted until frames come back; walk back to resumed (also the
      // only legal way onward from `paused`) before reading the render.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      // Asserted on the rendered transcript, not the session's status
      // alone — a prior bug here shipped because a test asserted backend
      // state while the screen rendered nothing a user could see.
      expect(find.text('App went to the background'), findsOneWidget);
      expect(find.text('Ended'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
      'inactive alone neither ends the session nor renders anything',
      (tester) async {
        await tester.pumpWidget(app());
        await tester.pump();

        // A Control Centre glance, an app-switcher flick and an incoming-call
        // banner all land here; ending a live conversation for any of them
        // would be worse than the auto-lock bug this unit fixes.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('App went to the background'), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('voice_status'))).data,
          'Listening',
        );

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  });
}

/// The WCAG 2.x contrast ratio. [Color.computeLuminance] is that standard's
/// relative luminance, so this is the whole of the formula.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// Owns [session] the way `HerdScreen` does in the app: disposes it when it
/// leaves the tree. [VoiceScreen] itself no longer does — a call outlives its
/// screen.
class _SessionOwner extends StatefulWidget {
  const _SessionOwner({required this.session, required this.child});

  final VoiceSession session;
  final Widget child;

  @override
  State<_SessionOwner> createState() => _SessionOwnerState();
}

class _SessionOwnerState extends State<_SessionOwner> {
  @override
  void dispose() {
    widget.session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
