import 'dart:async';
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
    Future<VoiceTransport> Function(String?)? connect,
    bool reduceMotion = false,
    ThemeData? theme,
  }) {
    final screen = VoiceScreen(
      session: VoiceSession(
        connect: connect ?? (_) async => transport,
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
      ),
    );
    return MaterialApp(
      theme: theme ?? droverDarkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // copyWith, not a bare MediaQueryData: the screen must still lay out
      // against a real screen size.
      home: reduceMotion
          ? Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: screen,
              ),
            )
          : screen,
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
  /// screen's own ground showing through whatever alpha the light left.
  Color onGround((int, int, int, int) pixel) {
    final (r, g, b, a) = pixel;
    final ground = droverDarkTheme.scaffoldBackgroundColor;
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
  Future<(Color, int)> worstGround(WidgetTester tester) async {
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
      )),
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
        connect: (_) async =>
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

  testWidgets('an errored session says so in the log, not the greeting', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(connect: (_) async => throw StateError('no host')),
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
        connect: (_) async =>
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
        connect: (_) async =>
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

  testWidgets('renders on the dark ground even under the light theme', (
    tester,
  ) async {
    await tester.pumpWidget(app(theme: droverLightTheme));
    await tester.pump();

    // The page itself...
    final page = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(Scaffold),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(page.color, droverDarkTheme.scaffoldBackgroundColor);
    // ...and what is painted on it: the DroverColors extension resolves to
    // the dark set, which only happens for a context taken below the Theme.
    expect(
      statusParagraph(tester).text.style?.color,
      DroverColors.dark.tertiaryText,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('takes the status bar light, and hands it back on pop', (
    tester,
  ) async {
    // Mirrors the call site: a light-theme route with an AppBar, which is
    // what publishes the overlay style the voice screen borrows — and, being
    // an annotation rather than a `SystemChrome` call, gives back on pop.
    // VoiceScreen owns the session's lifecycle, so nothing else disposes it.
    final session = VoiceSession(
      connect: (_) async => transport,
      mic: mic,
      speaker: speaker,
      tools: const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: droverLightTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(title: const Text('herd')),
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VoiceScreen(session: session),
                ),
              ),
              child: const Text('voice'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);

    await tester.tap(find.text('voice'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);

    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
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

    testWidgets('at rest the glow carries no colour, only the page ink', (
      tester,
    ) async {
      await onPhone(tester);
      await tester.pumpWidget(app());
      await tester.pump();

      // The tint rides the level, so a silent room is exactly the neutral
      // ink it has always been.
      final (r, g, b, a) = await cornerPixel(tester);
      debugPrint('rest corner rgba=$r,$g,$b,$a');
      expect(a, greaterThan(20), reason: 'no light to read a colour off');
      expect((r - g).abs(), lessThanOrEqualTo(3));
      expect((b - r).abs(), lessThanOrEqualTo(3));

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

    testWidgets('the assistant is never a dimmer light than silence', (
      tester,
    ) async {
      await onPhone(tester);
      await tester.pumpWidget(app());
      await tester.pump();
      final rest = onGround(await cornerPixel(tester)).computeLuminance();

      await pushSpeaker(tester, 1);
      final loud = onGround(await cornerPixel(tester)).computeLuminance();

      // The warm ink is a *colour* the light takes on, not a darker light:
      // a low-lightness warm at these alphas would leave the assistant's
      // glow dimmer than the resting one, which reads as the room going out
      // when it starts talking.
      debugPrint('bottom-edge luminance: rest=$rest loud speaking=$loud');
      expect(loud, greaterThanOrEqualTo(rest));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('every text clears 4.5:1 over the brightest glow there is', (
      tester,
    ) async {
      final drafts = VoiceDrafts();
      await tester.pumpWidget(app(herd: FakeVoiceHerd(), drafts: drafts));
      await tester.pump();
      transport.push(
        LiveServerToolCall(
          functionCalls: const [FunctionCall('list_agents', {}, id: 'c1')],
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
      };
      void clears(String state, Color ground) {
        debugPrint('$state ground=#${ground.toARGB32().toRadixString(16)}');
        for (final MapEntry(key: what, value: color) in texts.entries) {
          expect(
            contrastRatio(color, ground),
            greaterThanOrEqualTo(4.5),
            reason:
                '$what at ${color.toARGB32().toRadixString(16)} over the '
                '$state glow',
          );
        }
      }

      // The glow now has a colour, and the colour changes the ground under
      // every unbubbled line — so all three of them get checked, off the
      // render each time rather than computed from the constants.
      final (resting, _) = await worstGround(tester);
      clears('resting', resting);

      // Full level, and it stays there: the level only moves when a frame
      // lands, so each scan is one loudness throughout.
      await pushMic(tester, 0.99, times: 40);
      final (cool, peak) = await worstGround(tester);
      clears('loud listening', cool);

      await pushSpeaker(tester, 1);
      final (warm, _) = await worstGround(tester);
      clears('loud speaking', warm);

      // And the ceiling: the neutral ink is more luminous than either tint,
      // so the page's own ink at that same peak alpha is the brightest
      // ground this glow could ever make. The screen never paints it — a
      // loud glow always carries a tint — but the text is designed against
      // it, so it stays asserted.
      debugPrint('glow peak alpha=$peak/255');
      clears(
        'neutral ceiling',
        Color.alphaBlend(
          droverDarkTheme.colorScheme.onSurface.withValues(alpha: peak / 255),
          droverDarkTheme.scaffoldBackgroundColor,
        ),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

/// The WCAG 2.x contrast ratio. [Color.computeLuminance] is that standard's
/// relative luminance, so this is the whole of the formula.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}
