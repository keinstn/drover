import 'dart:async';
import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/infra/settings_store.dart';
import 'package:drover/src/infra/screen_wake.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/screens/agent_screen.dart';
import 'package:drover/src/screens/herd_screen.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
import 'package:drover/src/voice/voice_consent_sheet.dart';
import 'package:drover/src/voice/voice_herd.dart';
import 'package:drover/src/voice/voice_screen.dart';
import 'package:drover/src/voice/voice_session.dart';
import 'package:drover/src/voice/voice_transport.dart';
import 'package:drover/src/widgets/error_message_view.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../voice/fakes.dart';

class FakeCommandRunner extends CommandRunner {
  FakeCommandRunner(this._response);

  final CommandResult Function(String command) _response;
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

CommandResult ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

const _listEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent One"},'
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p2","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent Two"},'
    '{"agent":"claude","agent_status":"working","cwd":"/tmp/proj-b",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
    '"workspace_id":"wB","name":"Agent Three"}'
    ']}}';

CommandResult _respond(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'workspace' 'rename'") ||
      command.contains("'agent' 'rename'")) {
    return ok('{"id":"1","result":{"type":"ok"}}');
  }
  return ok(_listEnvelope);
}

/// Like [_respond], but reports a herdr version below [kMinHerdrVersion].
CommandResult _respondOldHerdr(String command) {
  if (command.contains("'--version'")) return ok('herdr 0.7.0\n');
  return _respond(command);
}

/// Like [_respondOldHerdr], but the background version probe (fired from
/// `initState`) fails its first call — as if it simply hadn't resolved yet —
/// so the bucket's cached version stays null. A later, deliberate
/// `--version` call (e.g. the launch-time authoritative re-check) succeeds
/// and reports the old version. Each call returns a fresh closure so the
/// call counter doesn't leak between tests.
CommandResult Function(String) _respondVersionUncachedThenOld() {
  var versionCalls = 0;
  return (command) {
    if (command.contains("'--version'")) {
      versionCalls++;
      if (versionCalls == 1) {
        return CommandResult(exitCode: 1, stdout: '', stderr: 'transient');
      }
      return ok('herdr 0.7.0\n');
    }
    return _respond(command);
  };
}

// The second host reuses host A's workspace/pane ids on purpose: they are
// only unique within a host, so the multi-host tests double as a check that
// nothing (keys included) collides across hosts.
const _hostBListEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"codex","agent_status":"blocked","cwd":"/tmp/proj-x",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent Bee"}'
    ']}}';

CommandResult _respondB(String command) {
  if (command.contains('command -v')) {
    return ok('claude\n');
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project X"}]}}',
    );
  }
  return ok(_hostBListEnvelope);
}

const _hostRef = HerdHostRef(
  hostId: 'host-1',
  displayName: 'Work Mac',
  revision: 0,
);
const _hostRefA = HerdHostRef(
  hostId: 'host-a',
  displayName: 'Host One',
  revision: 0,
);
const _hostRefB = HerdHostRef(
  hostId: 'host-b',
  displayName: 'Host Two',
  revision: 0,
);
const _hostRefEverConnected = HerdHostRef(
  hostId: 'host-a',
  displayName: 'Host One',
  revision: 0,
  hostEverConnected: true,
);

/// Any `Container` carrying a [BoxDecoration] — used with `find.ancestor` to
/// reach the nearest decorated box around a piece of text (a workspace card,
/// a status chip) and assert its geometry.
final _decoratedContainer = find.byWidgetPredicate(
  (widget) => widget is Container && widget.decoration is BoxDecoration,
);

/// The screen under test wrapped in an app shell. Single-client tests pass
/// [client]; multi-host tests pass [hosts] plus a [clientFor] resolver.
Widget _herdApp({
  HerdrClient? client,
  HerdrClient Function(HerdHostRef)? clientFor,
  List<HerdHostRef> hosts = const [_hostRef],
  String? filterHostId,
  Duration pollInterval = const Duration(hours: 1),
  VoidCallback? onOpenHostSwitcher,
  Locale? locale,
  Stream<void>? networkChanges,
  bool voiceAssistantEnabled = false,
  ThemeData? theme,
  ScreenWake? screenWake,
  VoiceSession Function({
    required VoiceHerd herd,
    required VoiceInbox inbox,
    required Locale? locale,
  })?
  voiceSessionFor,
}) {
  return MaterialApp(
    theme: theme ?? droverDarkTheme,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HerdScreen(
      hosts: hosts,
      clientFor: clientFor ?? (_) => client!,
      filterHostId: filterHostId,
      onOpenHostSwitcher: onOpenHostSwitcher ?? () {},
      onOpenSettings: () {},
      pollInterval: pollInterval,
      networkChanges: networkChanges,
      voiceAssistantEnabled: voiceAssistantEnabled,
      voiceSessionFor: voiceSessionFor,
      screenWake: screenWake,
    ),
  );
}

/// Stands in for [VoiceSession.forHerd] so the voice screen can be opened in
/// a widget test at all: the real one opens a microphone and dials Firebase
/// on `start()`, neither of which exists here, so every session it builds
/// fails at once and could never be resumable. Records what it built, so a
/// test can tell a continued conversation from a replaced one.
class FakeVoiceSessions {
  final connector = FakeConnector();
  final mic = FakeMic();
  final speaker = FakeSpeaker();
  final built = <VoiceSession>[];

  /// When set, a connect waits for it before landing — a dial still in the
  /// air, which is the one window where agent events can queue up while the
  /// call already counts as on the wire.
  Completer<void>? connectGate;

  /// Injected into every session built here, so a test can run a call's cap
  /// out without waiting five minutes.
  var clock = DateTime(2026, 1, 1);

  Future<VoiceTransport> _connect(String? handle, String sessionId) async {
    await connectGate?.future;
    return connector.call(handle, sessionId);
  }

  VoiceSession call({
    required VoiceHerd herd,
    required VoiceInbox inbox,
    required Locale? locale,
  }) {
    final session = VoiceSession(
      connect: _connect,
      now: () => clock,
      mic: mic,
      speaker: speaker,
      tools: const [],
      herd: herd,
      inbox: inbox,
    );
    built.add(session);
    return session;
  }
}

/// A [CommandRunner] backing two Claude agent panes with genuine native
/// session files (served via [statFile]/[readFile]), so `HerdScreen`'s
/// per-pane `NativeTranscriptHistory` cache can be exercised through the real
/// `ClaudeTranscriptLoader`/registry path (not a test double), the same as
/// production. Each pane's session-file "locate" (`find`) lookup is recorded
/// so a test can tell whether opening a pane reused an already-resolved
/// loader/path or re-resolved one from scratch.
class NativeHistoryHerdRunner extends CommandRunner {
  final commands = <String>[];

  /// pane id -> claude session id
  final sessions = <String, String>{
    'wA:p1': 'aaaaaaaa-0000-4000-8000-000000000001',
    'wB:p1': 'bbbbbbbb-0000-4000-8000-000000000002',
  };

  /// claude session id -> that session's JSONL contents.
  final sessionContents = <String, String>{
    'aaaaaaaa-0000-4000-8000-000000000001':
        '{"type":"user","message":{"role":"user","content":"Hello from A"}}\n',
    'bbbbbbbb-0000-4000-8000-000000000002':
        '{"type":"user","message":{"role":"user","content":"Hello from B"}}\n',
  };

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    if (command.contains("'workspace' 'list'")) {
      return ok(
        '{"id":"1","result":{"workspaces":['
        '{"workspace_id":"wA","label":"Project A"},'
        '{"workspace_id":"wB","label":"Project B"}'
        ']}}',
      );
    }
    if (command.contains("'agent' 'list'")) {
      // Mirrors production herdr, whose list entries carry agent_session —
      // AgentScreen now resolves the current agent (and its native history)
      // from `agent list`, not `agent get`.
      final entries = sessions.keys.map((paneId) {
        final workspaceId = paneId.split(':').first;
        final sessionId = sessions[paneId];
        return '{"agent":"claude","agent_status":"idle",'
            '"cwd":"/tmp/proj","focused":false,"pane_id":"$paneId",'
            '"tab_id":"$workspaceId:t1","workspace_id":"$workspaceId",'
            '"name":"Agent $paneId",'
            '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
            '"value":"$sessionId"}}';
      });
      return ok('{"id":"1","result":{"agents":[${entries.join(',')}]}}');
    }
    if (command.contains("'agent' 'get'")) {
      final paneId = sessions.keys.firstWhere(
        (id) => command.contains("'$id'"),
      );
      final workspaceId = paneId.split(':').first;
      final sessionId = sessions[paneId];
      return ok(
        '{"id":"1","result":{"agent":{"agent":"claude","agent_status":"idle",'
        '"cwd":"/tmp/proj","focused":false,"pane_id":"$paneId",'
        '"tab_id":"$workspaceId:t1","workspace_id":"$workspaceId",'
        '"name":"Agent $paneId",'
        '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
        '"value":"$sessionId"}}}}',
      );
    }
    if (command.contains("'agent' 'read'")) {
      return ok('working…');
    }
    if (command.startsWith('command find ')) {
      final match = RegExp(r"-name '([^']+)\.jsonl'").firstMatch(command);
      final sessionId = match?.group(1);
      return ok('/home/dev/.claude/projects/-tmp-proj/$sessionId.jsonl\n');
    }
    return ok('{"id":"1","result":{}}');
  }

  String? _sessionIdFromPath(String path) {
    final fileName = path.split('/').last;
    return fileName.endsWith('.jsonl')
        ? fileName.substring(0, fileName.length - '.jsonl'.length)
        : null;
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    final text = sessionContents[_sessionIdFromPath(path)] ?? '';
    return RemoteFileStat(size: utf8.encode(text).length);
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    final text = sessionContents[_sessionIdFromPath(path)] ?? '';
    final bytes = utf8.encode(text);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('the voice button is hidden when the assistant is off', (
    tester,
  ) async {
    final client = HerdrClient(FakeCommandRunner(_respond));
    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();

    expect(find.byKey(const ValueKey('voice_button')), findsNothing);
    // The FAB row still carries the launch FAB on its own.
    expect(find.byKey(const ValueKey('launch_agent_fab')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the voice button shows when the assistant is enabled', (
    tester,
  ) async {
    final client = HerdrClient(FakeCommandRunner(_respond));
    await tester.pumpWidget(
      _herdApp(client: client, voiceAssistantEnabled: true),
    );
    await tester.pump();

    // Not tapped: that would try to connect to Firebase.
    final voiceButton = find.byKey(const ValueKey('voice_button'));
    expect(voiceButton, findsOneWidget);
    // Placed in the Scaffold's FAB slot beside the launch FAB, not the AppBar.
    expect(
      find.ancestor(of: voiceButton, matching: find.byType(AppBar)),
      findsNothing,
    );
    final launchFab = find.byKey(const ValueKey('launch_agent_fab'));
    expect(tester.getSize(voiceButton), const Size(48, 48));
    expect(
      tester.getTopLeft(voiceButton).dx,
      greaterThan(tester.getTopRight(launchFab).dx),
    );
    expect(tester.getCenter(voiceButton).dy, tester.getCenter(launchFab).dy);
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  group('voice consent', () {
    Future<void> openHerd(WidgetTester tester) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(client: client, voiceAssistantEnabled: true),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
    }

    testWidgets('the first tap renders the disclosure naming Google', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await openHerd(tester);

      expect(find.text('Voice uses Google Gemini'), findsOneWidget);
      expect(
        find.textContaining("Google's Gemini Live", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('microphone audio', findRichText: true),
        findsOneWidget,
      );
      // Both sides are transcribed server-side (inputAudioTranscription and
      // outputAudioTranscription), so the disclosure has to say so.
      expect(
        find.textContaining('both sides', findRichText: true),
        findsOneWidget,
      );
      // The mic stays open while the user walks around drover, and coming
      // back re-dials with no tap of the user's. The sheet is what the
      // permission rests on, so it has to say both rather than leave "you
      // left the voice screen, it stopped".
      expect(
        find.textContaining(
          'keeps listening while you use the rest of drover',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          're-opens the microphone by itself and carries on where you left off',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Allow and continue'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.byType(VoiceScreen), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('declining stays on the herd screen and records nothing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await openHerd(tester);
      await tester.tap(find.byKey(const ValueKey('voice_consent_decline')));
      await tester.pumpAndSettle();

      expect(find.byType(VoiceScreen), findsNothing);
      expect(find.text('Voice uses Google Gemini'), findsNothing);
      expect(find.byKey(const ValueKey('voice_button')), findsOneWidget);
      expect(
        (await SettingsStore().load()).voiceConsentVersion,
        0,
        reason: 'a decline must not be remembered as consent',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('accepting opens the voice screen and is remembered', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await openHerd(tester);
      await tester.tap(find.byKey(const ValueKey('voice_consent_accept')));
      await tester.pumpAndSettle();

      expect(find.byType(VoiceScreen), findsOneWidget);
      expect(
        (await SettingsStore().load()).voiceConsentVersion,
        kVoiceConsentVersion,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a later tap goes straight to the session, no sheet', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'voice_consent_version': kVoiceConsentVersion,
      });

      await openHerd(tester);

      expect(find.text('Voice uses Google Gemini'), findsNothing);
      expect(find.byType(VoiceScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('an accept of the old disclosure is asked again', (
      tester,
    ) async {
      // What installs from before the consent was versioned carry: a bare
      // boolean under the old key. They accepted a sheet that said leaving
      // the app ends the session, and would otherwise get the microphone
      // re-opening by itself on a yes they never gave.
      SharedPreferences.setMockInitialValues({'voice_consent_accepted': true});

      await openHerd(tester);

      expect(find.text('Voice uses Google Gemini'), findsOneWidget);
      expect(find.byType(VoiceScreen), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('an accept of version 1 is asked again', (tester) async {
      // A literal, not `kVoiceConsentVersion - 1`: what this pins is the
      // bump that came with this branch's copy. Version 1 said leaving the
      // voice screen closed the microphone; it now stays open while the user
      // is anywhere in drover, which is a yes they have not given.
      SharedPreferences.setMockInitialValues({'voice_consent_version': 1});

      await openHerd(tester);

      expect(find.text('Voice uses Google Gemini'), findsOneWidget);
      expect(
        find.textContaining(
          'keeps listening while you use the rest of drover',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.byType(VoiceScreen), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('an accept of an older disclosure version is asked again', (
      tester,
    ) async {
      // Written against the constant rather than a literal, so the next bump
      // is covered by this test the day it lands.
      SharedPreferences.setMockInitialValues({
        'voice_consent_version': kVoiceConsentVersion - 1,
      });

      await openHerd(tester);

      expect(find.text('Voice uses Google Gemini'), findsOneWidget);
      expect(find.byType(VoiceScreen), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('retaining the conversation', () {
    late FakeVoiceSessions sessions;

    setUp(() {
      sessions = FakeVoiceSessions();
      // Consent is a separate gate, exercised above; here it is out of the
      // way so the first tap goes straight to the screen.
      SharedPreferences.setMockInitialValues({
        'voice_consent_version': kVoiceConsentVersion,
      });
    });

    FloatingActionButton voiceFab(WidgetTester tester) =>
        tester.widget(find.byKey(const ValueKey('voice_button')));

    Finder voiceIcon(IconData icon) => find.descendant(
      of: find.byKey(const ValueKey('voice_button')),
      matching: find.byIcon(icon),
    );

    /// Opens the voice screen, puts a line in the log so a conversation that
    /// carried over is recognisable, lets the server offer a resumption
    /// handle — the one a call the user *ended* would need — and comes back
    /// to the herd screen.
    Future<void> callAndLeave(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      // A new call costs a credit, so the voice screen waits to be told to
      // dial. Only the first visit needs this: once the conversation exists,
      // re-entering continues it for free and by itself.
      await tester.tap(find.byKey(const ValueKey('voice_start_button')));
      await tester.pumpAndSettle();
      sessions.connector.last.push(
        LiveServerContent(
          outputTranscription: const Transcription(
            text: 'One agent is blocked.',
          ),
          turnComplete: true,
        ),
      );
      sessions.connector.last.pushResumption('h1');
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }

    testWidgets('re-opening returns to the call still running', (tester) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();

      await callAndLeave(tester);
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();

      // The log of the first visit is still on screen and nothing was torn
      // down in between: one session, one socket, no reconnect and no fresh
      // call's greeting.
      expect(find.text('One agent is blocked.'), findsOneWidget);
      expect(find.text('What should we start on?'), findsNothing);
      expect(find.text('Reconnected, continuing'), findsNothing);
      expect(sessions.built, hasLength(1));
      expect(sessions.connector.transports, hasLength(1));
      expect(sessions.connector.handles, [null]);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    for (final (name, theme, ink) in [
      ('dark', droverDarkTheme, const Color(0xFF8FC0F2)),
      ('light', droverLightTheme, const Color(0xFF388ADC)),
    ]) {
      testWidgets('the voice button wears the live call ($name)', (
        tester,
      ) async {
        final client = HerdrClient(FakeCommandRunner(_respond));
        await tester.pumpWidget(
          _herdApp(
            client: client,
            theme: theme,
            voiceAssistantEnabled: true,
            voiceSessionFor: sessions.call,
          ),
        );
        await tester.pump();

        expect(voiceFab(tester).backgroundColor, theme.colorScheme.primary);
        expect(voiceIcon(Icons.graphic_eq), findsOneWidget);

        await callAndLeave(tester);

        // With the voice screen gone the only other sign a mic is open is
        // the OS indicator, so this button carries its own: the voice
        // screen's listening ink and an open microphone, in place of the
        // page's accent and a waveform.
        expect(voiceFab(tester).backgroundColor, ink);
        expect(
          voiceFab(tester).backgroundColor,
          isNot(theme.colorScheme.primary),
        );
        expect(voiceIcon(Icons.mic), findsOneWidget);
        expect(voiceIcon(Icons.graphic_eq), findsNothing);
        expect(voiceFab(tester).tooltip, 'Voice call in progress');

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }

    testWidgets('leaving the app ends the call from the herd screen', (
      tester,
    ) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();

      await callAndLeave(tester);
      expect(voiceIcon(Icons.mic), findsOneWidget);

      // The voice screen is popped, so its observer is gone: this screen's
      // is the only one left to close the mic. Walked through the real
      // sequence, and back again — `AppLifecycleListener` asserts on invalid
      // transitions, and Flutter produces no frames while paused.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      // The button says so: back to idle, with no mic open behind it. And
      // nothing re-dialled on the way back — re-opening the microphone is
      // the voice screen's to do.
      expect(voiceIcon(Icons.graphic_eq), findsOneWidget);
      expect(voiceIcon(Icons.mic), findsNothing);
      expect(sessions.connector.transports, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();

      // Same conversation, continued on the handle, with why it ended in
      // the log.
      expect(find.text('App went to the background'), findsOneWidget);
      expect(find.text('One agent is blocked.'), findsOneWidget);
      expect(sessions.built, hasLength(1));
      expect(sessions.connector.handles, [null, 'h1']);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // And the button is live again on the way out: it follows the session
      // it was handed, whether that call was freshly built or resumed.
      expect(voiceIcon(Icons.mic), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a pending event still badges the live button', (tester) async {
      var list = _listEnvelope;
      final client = HerdrClient(
        FakeCommandRunner(
          (c) => c.contains("'agent' 'list'") ? ok(list) : _respond(c),
        ),
      );
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
          pollInterval: const Duration(seconds: 1),
        ),
      );
      await tester.pump();
      await tester.pump();

      // A dial still in the air: the call already counts as on the wire, but
      // no transport has landed to drain the inbox into, so an event that
      // arrives now stays pending — the one window where both signs are true
      // at once.
      sessions.connectGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice_start_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      list = _listEnvelope.replaceFirst(
        '"agent_status":"working"',
        '"agent_status":"idle"',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(voiceIcon(Icons.mic), findsOneWidget);
      expect(
        tester
            .widget<Badge>(find.byKey(const ValueKey('voice_badge')))
            .isLabelVisible,
        isTrue,
      );

      sessions.connectGate!.complete();
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    group('the composer microphone', () {
      // Two microphones, one AVAudioSession: `speech_to_text` would put
      // SFSpeechRecognizer's tap on the session `record` already holds for
      // the call. Since the call now survives leaving the voice screen, that
      // collision is one Back and one tap away, so the composer's mic yields
      // while a call is up — `AgentScreen.canDictate`, not a withheld
      // controller, so who owns the speech plugin is unchanged.
      final composer = find.byKey(const ValueKey('agent_composer'));
      final dictate = find.byKey(const ValueKey('dictate_button'));

      Future<void> openAgent(WidgetTester tester, {required bool call}) async {
        await tester.pumpWidget(
          _herdApp(
            client: HerdrClient(FakeCommandRunner(_respond)),
            voiceAssistantEnabled: true,
            voiceSessionFor: sessions.call,
          ),
        );
        await tester.pump();
        if (call) await callAndLeave(tester);
        await tester.tap(find.text('Agent One'));
        await tester.pumpAndSettle();
      }

      testWidgets('is there when no call is up', (tester) async {
        await openAgent(tester, call: false);

        expect(composer, findsOneWidget);
        expect(dictate, findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('is gone while a call is on the wire', (tester) async {
        await openAgent(tester, call: true);

        // The composer is still there and still types — it is the mic alone
        // that yields, not the way to send a message.
        expect(composer, findsOneWidget);
        expect(dictate, findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    });

    group('screen wake', () {
      // The wake follows the call, not the screen that started it: the user
      // is talking and touching nothing, and an auto-lock backgrounds the
      // app, which ends the call. Stepping back to the herd screen to look
      // at the agents must not start that clock.
      late FakeScreenWake wake;

      setUp(() => wake = FakeScreenWake());

      Future<void> pumpHerd(WidgetTester tester, {bool enabled = true}) async {
        await tester.pumpWidget(
          _herdApp(
            client: HerdrClient(FakeCommandRunner(_respond)),
            voiceAssistantEnabled: enabled,
            voiceSessionFor: sessions.call,
            screenWake: wake,
          ),
        );
        await tester.pump();
      }

      testWidgets('goes on with the call and off when it ends', (tester) async {
        await pumpHerd(tester);

        expect(wake.calls, isEmpty, reason: 'no call, nothing to hold');

        await tester.tap(find.byKey(const ValueKey('voice_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('voice_start_button')));
        await tester.pumpAndSettle();

        expect(wake.calls, [true]);

        await tester.tap(find.byKey(const ValueKey('voice_action_button')));
        await tester.pumpAndSettle();

        expect(wake.calls, [true, false]);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('is still held after the user leaves the voice screen', (
        tester,
      ) async {
        await pumpHerd(tester);

        await callAndLeave(tester);

        // The whole point: the call is live on the herd screen, so the idle
        // timer must still be held off. One `true`, never released.
        expect(voiceIcon(Icons.mic), findsOneWidget);
        expect(wake.calls, [true]);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('Restart turns the wake back on', (tester) async {
        await pumpHerd(tester);
        await tester.tap(find.byKey(const ValueKey('voice_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('voice_start_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('voice_action_button')));
        await tester.pumpAndSettle();

        expect(wake.calls, [true, false]);

        await tester.tap(find.byKey(const ValueKey('voice_action_button')));
        await tester.pumpAndSettle();

        expect(sessions.connector.transports, hasLength(2));
        expect(wake.calls, [true, false, true]);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('is released when the retained call is dropped', (
        tester,
      ) async {
        await pumpHerd(tester);
        await callAndLeave(tester);

        expect(wake.calls, [true]);

        // The Settings toggle going off drops a call that is still live —
        // the session goes, and the wake must go with it rather than pin the
        // device awake behind a call that no longer exists.
        await pumpHerd(tester, enabled: false);

        expect(wake.calls, [true, false]);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('is released when the herd screen is disposed', (
        tester,
      ) async {
        await pumpHerd(tester);
        await callAndLeave(tester);

        expect(wake.calls, [true]);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        expect(wake.calls, [true, false]);
      });
    });

    /// Opens the voice screen, starts a call and leaves it parked with no
    /// resumption handle — the first seconds of a call, and every mid-call
    /// reconnect, since a reconnect consumes the handle it had. Backgrounded
    /// from the herd screen, so the voice screen's own observer is out of it.
    Future<void> startAndPark(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice_start_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a handle-less park is not charged for twice', (tester) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();

      await startAndPark(tester);
      // Back in, and Restart rather than Start: with no handle the screen
      // cannot pick the conversation up by itself.
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      expect(sessions.built, hasLength(1), reason: 'the same call, kept');
      await tester.tap(find.byKey(const ValueKey('voice_action_button')));
      await tester.pumpAndSettle();

      // The money: two connects under one session id, so the re-mint lands
      // inside the server's reuse window and the call is paid for once. The
      // navigation in the middle must not change that.
      expect(sessions.connector.sessionIds, hasLength(2));
      expect(
        sessions.connector.sessionIds.toSet(),
        hasLength(1),
        reason: 'one call, one debit',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a park past its cap is not retained', (tester) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();

      await startAndPark(tester);
      // Away long enough that the call is over, not paused: there is nothing
      // left to continue, so the next one is a new call and pays.
      sessions.clock = sessions.clock.add(kVoiceSessionCap);
      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();

      expect(sessions.built, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a call the user ended is replaced by a fresh one', (
      tester,
    ) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice_start_button')));
      await tester.pumpAndSettle();
      sessions.connector.last.pushResumption('h1');
      await tester.pump();
      // End, then leave: a handle is in hand, so the End alone is what makes
      // this conversation spent.
      await tester.tap(find.byKey(const ValueKey('voice_action_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice_close_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice_start_button')));
      await tester.pumpAndSettle();

      expect(find.text('What should we start on?'), findsOneWidget);
      expect(find.text('Session ended'), findsNothing);
      expect(sessions.built, hasLength(2));
      expect(sessions.connector.handles, [null, null]);
      // Two calls, two ids, two credits: an End is what makes the next Start
      // pay again.
      expect(sessions.connector.sessionIds.toSet(), hasLength(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('turning the assistant off drops the retained call', (
      tester,
    ) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      Widget app({required bool enabled}) => _herdApp(
        client: client,
        voiceAssistantEnabled: enabled,
        voiceSessionFor: sessions.call,
      );
      await tester.pumpWidget(app(enabled: true));
      await tester.pump();

      await callAndLeave(tester);
      // The user's revoke, and then a change of mind: what must not survive
      // the off is the conversation held while it was on.
      await tester.pumpWidget(app(enabled: false));
      await tester.pump();
      await tester.pumpWidget(app(enabled: true));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();

      expect(find.text('What should we start on?'), findsOneWidget);
      expect(find.text('One agent is blocked.'), findsNothing);
      expect(sessions.built, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    /// Every `[focus]` hint that reached the model on the current socket.
    List<String> focusHints() => sessions.connector.last.sentText
        .where((text) => text.startsWith('[focus] '))
        .toList();

    testWidgets('opening an agent tells the call whose screen is open', (
      tester,
    ) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      await tester.pumpWidget(
        _herdApp(
          client: client,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();

      await callAndLeave(tester);
      final loggedBefore = sessions.built.single.entries.length;
      await tester.tap(find.text('Agent One'));
      await tester.pumpAndSettle();

      // The call is still up behind the agent screen, and now knows which
      // agent "it" means.
      expect(focusHints(), hasLength(1));
      expect(focusHints().single, contains('Agent One'));

      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      expect(focusHints(), hasLength(2));
      expect(focusHints().last, contains('no longer looking'));
      // Navigation, not conversation: two hints went to the model and the
      // log grew by nothing.
      expect(sessions.built.single.entries, hasLength(loggedBefore));

      // Torn down with an agent screen still on top, so the release runs
      // against a herd screen that may already be going.
      await tester.tap(find.text('Agent One'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('an agent on a host the call is not scoped to is not named', (
      tester,
    ) async {
      final clientA = HerdrClient(FakeCommandRunner(_respond));
      final clientB = HerdrClient(FakeCommandRunner(_respondB));
      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
          voiceAssistantEnabled: true,
          voiceSessionFor: sessions.call,
        ),
      );
      await tester.pump();
      await tester.pump();

      await callAndLeave(tester);
      // The session was built for host A (the first in scope); host B's
      // "Agent Bee" is a name its tools could not resolve.
      await tester.scrollUntilVisible(find.text('Agent Bee'), 100);
      await tester.tap(find.text('Agent Bee'));
      await tester.pumpAndSettle();

      expect(focusHints(), isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('the host in scope changing drops the retained call', (
      tester,
    ) async {
      final clientA = HerdrClient(FakeCommandRunner(_respond));
      final clientB = HerdrClient(FakeCommandRunner(_respondB));
      Widget app(String hostId) => _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        filterHostId: hostId,
        voiceAssistantEnabled: true,
        voiceSessionFor: sessions.call,
      );
      await tester.pumpWidget(app('host-a'));
      await tester.pump();

      await callAndLeave(tester);
      // The session's tools talk to host A's client alone, so it cannot
      // follow the user to host B.
      await tester.pumpWidget(app('host-b'));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();

      expect(find.text('What should we start on?'), findsOneWidget);
      expect(find.text('One agent is blocked.'), findsNothing);
      expect(sessions.built, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('the voice switcher bar', () {
    late FakeVoiceSessions sessions;

    setUp(() {
      sessions = FakeVoiceSessions();
      SharedPreferences.setMockInitialValues({
        'voice_consent_version': kVoiceConsentVersion,
      });
    });

    testWidgets('tapping an agent in the bar opens it with the call still on', (
      tester,
    ) async {
      final client = HerdrClient(FakeCommandRunner(_respond));
      Color? listeningInk;
      await tester.pumpWidget(
        MaterialApp(
          theme: droverDarkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              // Read off the same theme the screens render under, so the
              // expectation cannot drift from the screen-private constant.
              listeningInk = voiceListeningInk(context);
              return HerdScreen(
                hosts: const [_hostRef],
                clientFor: (_) => client,
                onOpenHostSwitcher: () {},
                onOpenSettings: () {},
                pollInterval: const Duration(hours: 1),
                voiceAssistantEnabled: true,
                voiceSessionFor: sessions.call,
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('voice_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice_start_button')));
      await tester.pumpAndSettle();

      // Seeded before the push: with a one-hour poll interval no listAgents
      // has landed since the call opened, so the roster can only be there
      // because `_openVoice` seeded it rather than the poll filling it in.
      expect(find.byType(VoiceScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('switcher_agent_wA:p2')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('switcher_agent_wA:p2')));
      // Route transition plus the bar's own slide; not pumpAndSettle,
      // because the pushed screen polls on a timer.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The agent is on screen, on top of the call...
      expect(find.byType(AgentScreen), findsOneWidget);
      expect(find.text('Agent Two'), findsWidgets);

      // ...and its way back wears the "we are listening" ink, off the
      // render rather than off the constructor argument.
      final ink = tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(const ValueKey('agent_back_button')),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .color!;
      expect(ink, listeningInk);
      expect(ink, isNot(droverDarkTheme.colorScheme.onSurfaceVariant));

      // And the call is still the one call: nothing was torn down or
      // re-dialled to put this screen on top of it.
      expect(sessions.built, hasLength(1));
      expect(sessions.connector.transports, hasLength(1));

      // The return leg: that ink is a promise about where back goes, so
      // press it and land on the call — still the same one.
      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pump();
      // Two waits, not one: the first covers the pop transition, the second
      // the frame that disposes the popped route. Not pumpAndSettle — the
      // agent screen polls on a timer until it is gone.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(VoiceScreen), findsOneWidget);
      expect(find.byType(AgentScreen), findsNothing);
      expect(sessions.built, hasLength(1));
      expect(sessions.connector.transports, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  testWidgets('the voice button shows a badge once an agent finishes', (
    tester,
  ) async {
    // Agent Three starts working; the second poll reports it idle.
    var list = _listEnvelope;
    final client = HerdrClient(
      FakeCommandRunner(
        (c) => c.contains("'agent' 'list'") ? ok(list) : _respond(c),
      ),
    );
    await tester.pumpWidget(
      _herdApp(
        client: client,
        voiceAssistantEnabled: true,
        pollInterval: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    await tester.pump();

    Badge badge() =>
        tester.widget<Badge>(find.byKey(const ValueKey('voice_badge')));
    expect(badge().isLabelVisible, isFalse);

    list = _listEnvelope.replaceFirst(
      '"agent_status":"working"',
      '"agent_status":"idle"',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(badge().isLabelVisible, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no voice badge when the assistant is off', (tester) async {
    var list = _listEnvelope;
    final client = HerdrClient(
      FakeCommandRunner(
        (c) => c.contains("'agent' 'list'") ? ok(list) : _respond(c),
      ),
    );
    await tester.pumpWidget(
      _herdApp(client: client, pollInterval: const Duration(seconds: 1)),
    );
    await tester.pump();
    await tester.pump();
    list = _listEnvelope.replaceFirst(
      '"agent_status":"working"',
      '"agent_status":"idle"',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.byKey(const ValueKey('voice_badge')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows session titles grouped by workspace, blocked above idle', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Agent One'), findsOneWidget);
    expect(find.textContaining('Agent Two'), findsOneWidget);
    expect(find.textContaining('Agent Three'), findsOneWidget);
    expect(find.text('Project A'), findsOneWidget);
    expect(find.text('Project B'), findsOneWidget);
    expect(find.text('wA'), findsNothing);
    expect(find.text('wB'), findsNothing);
    expect(find.textContaining('p1'), findsNothing);
    expect(find.textContaining('p2'), findsNothing);
    // A single stored host renders no host section header.
    expect(find.text('Work Mac'), findsNothing);
    // No pane was opened, so every tile's activity snippet falls back to the
    // `agentType · cwd` metadata.
    expect(find.text('claude · proj-a'), findsNWidgets(2));
    expect(find.text('claude · proj-b'), findsOneWidget);

    final blockedTop = tester.getTopLeft(find.textContaining('Agent Two')).dy;
    final idleTop = tester.getTopLeft(find.textContaining('Agent One')).dy;
    expect(blockedTop, lessThan(idleTop));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('greets with the blocked count and a per-status chip row', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    // One agent is blocked in the fixture, so the greeting names that count.
    expect(find.textContaining('1 agent', findRichText: true), findsOneWidget);

    // The chip row shows every status with its count (0 included), using the
    // renewed human labels.
    expect(find.text('WAITING FOR YOU 1'), findsOneWidget);
    expect(find.text('WORKING 1'), findsOneWidget);
    expect(find.text('ALL DONE 0'), findsOneWidget);
    expect(find.text('RESTING 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('greets all-clear when nothing is blocked', (tester) async {
    const envelope =
        '{"id":"1","result":{"agents":['
        '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
        '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
        '"workspace_id":"wA","name":"Agent One"}'
        ']}}';
    final runner = FakeCommandRunner((command) {
      if (command.contains("'workspace' 'list'")) {
        return ok(
          '{"id":"1","result":{"workspaces":['
          '{"workspace_id":"wA","label":"Project A"}]}}',
        );
      }
      return ok(envelope);
    });
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining("Everyone's on track.", findRichText: true),
      findsOneWidget,
    );
    // The waiting-count greeting (and its accent count) is absent.
    expect(
      find.textContaining('waiting for your reply', findRichText: true),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'suspends periodic list polling while AgentScreen is open, resumes '
    'after popping',
    (tester) async {
      final runner = FakeCommandRunner(_respond);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        _herdApp(client: client, pollInterval: const Duration(seconds: 1)),
      );
      await tester.pump();
      await tester.pump();

      int listCalls() =>
          runner.commands.where((c) => c.contains("'agent' 'list'")).length;

      // Two polling ticks confirm the periodic poll is indeed running before
      // the detail route is pushed.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      final beforePush = listCalls();
      expect(beforePush, greaterThan(1));

      await tester.tap(find.text('Agent One'));
      await tester.pumpAndSettle();
      final atPush = listCalls();

      // While AgentScreen is open (pushed on top), the herd's own 1s poll
      // must stay suspended. AgentScreen legitimately polls `agent list`
      // itself for the switcher bar on its default 2s interval, so exactly
      // one call lands in these three elapsed seconds — the herd's cadence
      // would have added three more.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(listCalls(), atPush + 1);

      // Popping back resumes polling — an immediate refresh fires right
      // away, without waiting for the next tick.
      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();
      expect(listCalls(), greaterThan(atPush));

      final afterPop = listCalls();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(listCalls(), greaterThan(afterPop));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shows the agent CLI terminal title (CLI suffix stripped) as the tile '
    'title',
    (tester) async {
      const envelope =
          '{"id":"1","result":{"agents":['
          '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
          '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
          '"workspace_id":"wB",'
          '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
          ']}}';
      final runner = FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}]}}',
          );
        }
        return ok(envelope);
      });
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      expect(find.text('Herd の session 表示を設計'), findsOneWidget);
      expect(
        find.textContaining('GitHub Copilot'),
        findsNothing,
        reason: 'the CLI-specific suffix is stripped from the title',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reuses a pane\'s native transcript history/loader across leaving and '
    'reopening its AgentScreen, keeping a separate one per pane',
    (tester) async {
      final runner = NativeHistoryHerdRunner();
      final client = HerdrClient(runner);
      final sessionA = runner.sessions['wA:p1']!;
      final sessionB = runner.sessions['wB:p1']!;

      int locateCallsFor(String sessionId) => runner.commands
          .where((c) => c.contains("-name '$sessionId.jsonl'"))
          .length;

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      // Open pane A: its native history loads (one session-file locate).
      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from A'), findsOneWidget);
      expect(locateCallsFor(sessionA), 1);

      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      // Reopening the very same pane must reuse the cached
      // NativeTranscriptHistory/loader instance (resuming from its
      // already-known path/offset) rather than re-locating the session file
      // from scratch.
      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from A'), findsOneWidget);
      expect(locateCallsFor(sessionA), 1);

      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      // A different pane gets its own, independent history/loader: opening
      // it locates its own session file, and pane A's cached state (and
      // locate count) is unaffected.
      await tester.tap(find.text('Agent wB:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from B'), findsOneWidget);
      expect(locateCallsFor(sessionB), 1);
      expect(locateCallsFor(sessionA), 1);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'tile activity snippet reflects the pane\'s cached transcript once opened',
    (tester) async {
      final runner = NativeHistoryHerdRunner();
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      // Before opening, the snippet is the metadata fallback (no cached
      // transcript yet).
      expect(find.text('claude · proj'), findsNWidgets(2));
      expect(find.text('Hello from A'), findsNothing);

      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      // Back on the herd, that pane's tile now derives its snippet from the
      // loaded native transcript; the other pane still shows the fallback.
      expect(find.text('Hello from A'), findsOneWidget);
      expect(find.text('claude · proj'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shows the launch-agent FAB', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('launch_agent_fab')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('workspace card uses the large radius and an outlineVariant '
      'hairline', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    final decoration =
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text('Project A'),
                        matching: _decoratedContainer,
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(droverRadiusLarge));
    // Dark had no card hairline at all before the ink redesign.
    expect(
      decoration.border,
      Border.all(color: droverDarkTheme.colorScheme.outlineVariant),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status filter chip is a pill', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    final decoration =
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text('WAITING FOR YOU 1'),
                        matching: _decoratedContainer,
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(999));
    // Pins identity too, so the assertion fails rather than drifts if
    // `find.ancestor` ever resolves to some other decorated box.
    expect(
      decoration.color,
      DroverColors.dark.statusPillBg(AgentStatus.blocked),
    );
    expect(
      decoration.border,
      Border.all(
        color: DroverColors.dark
            .statusDot(AgentStatus.blocked)
            .withValues(alpha: 0.34),
      ),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('label ramp leaves Japanese uncased', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    // The launch FAB's caption is a fixed localized string, which is what
    // the ramp is for — a workspace label is user-chosen and stays off it.
    // Asserting both directions keeps this from passing trivially if the
    // ramp's case treatment were dropped altogether.
    await tester.pumpWidget(
      _herdApp(client: client, locale: const Locale('en')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('LAUNCH AGENT'), findsOneWidget);
    expect(find.text('Launch agent'), findsNothing);

    await tester.pumpWidget(
      _herdApp(client: client, locale: const Locale('ja')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('エージェントを起動'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a warning when the host\'s herdr is too old', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respondOldHerdr);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('herdr_version_warning_host-1')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('blocks launching a new agent when the herdr is too old', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respondOldHerdr);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
    await tester.pumpAndSettle();

    expect(find.byType(LaunchAgentSheet), findsNothing);
    expect(runner.commands.any((c) => c.contains("'agent' 'start'")), isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'blocks launching when the herdr version was not yet cached (race with '
    'the background probe)',
    (tester) async {
      final runner = FakeCommandRunner(_respondVersionUncachedThenOld());
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      // The background probe's first (only, so far) call failed, so no
      // cached warning is shown yet.
      expect(
        find.byKey(const ValueKey('herdr_version_warning_host-1')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
      await tester.pumpAndSettle();

      expect(find.byType(LaunchAgentSheet), findsNothing);
      expect(
        runner.commands.any((c) => c.contains("'agent' 'start'")),
        isFalse,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('chip reads "All hosts" when no host filter is set', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.text('Drover'), findsOneWidget);
    expect(find.byKey(const ValueKey('host_switcher_chip')), findsOneWidget);
    expect(find.text('All hosts'), findsOneWidget);
    expect(find.text('Work Mac'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'chip shows the filtered host name and opens the switcher when tapped',
    (tester) async {
      var switcherCalls = 0;
      final runner = FakeCommandRunner(_respond);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        _herdApp(
          client: client,
          filterHostId: 'host-1',
          onOpenHostSwitcher: () => switcherCalls++,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Drover'), findsOneWidget);
      expect(find.text('Work Mac'), findsOneWidget);
      expect(find.text('All hosts'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('host_switcher_chip')));
      await tester.pump();

      expect(switcherCalls, 1);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('left swipe asks for confirmation before stopping an agent', (
    tester,
  ) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('agent-host-1-wA:p1')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stop agent?'), findsOneWidget);
    expect(find.textContaining('Agent One (wA:p1)'), findsOneWidget);
    expect(
      runner.commands,
      isNot(contains("~/.local/bin/herdr 'pane' 'close' 'wA:p1'")),
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Stop agent?'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stops an agent after confirming a left swipe', (tester) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('agent-host-1-wA:p1')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pumpAndSettle();

    expect(
      runner.commands,
      contains("~/.local/bin/herdr 'pane' 'close' 'wA:p1'"),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long press on workspace header renames workspace', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.text('Project A'));
    await tester.pumpAndSettle();

    expect(find.text('Rename workspace'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Delivery');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      runner.commands,
      contains("~/.local/bin/herdr 'workspace' 'rename' 'wA' 'Delivery'"),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long press on an agent renames the agent', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('agent-host-1-wA:p1')));
    await tester.pumpAndSettle();

    expect(find.text('Rename agent'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Pair Driver');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      runner.commands,
      contains("~/.local/bin/herdr 'agent' 'rename' 'wA:p1' 'Pair Driver'"),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'rename dialog prefills with the agent slug name, not the session title',
    (tester) async {
      const envelope =
          '{"id":"1","result":{"agents":['
          '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
          '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
          '"workspace_id":"wB","name":"scout",'
          '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
          ']}}';
      final runner = FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}]}}',
          );
        }
        return ok(envelope);
      });
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const ValueKey('agent-host-1-wB:p1')));
      await tester.pumpAndSettle();

      expect(find.text('Rename agent'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'scout'),
        findsOneWidget,
        reason: 'the field prefills with the editable slug name',
      );
      expect(
        find.widgetWithText(TextField, 'Herd の session 表示を設計'),
        findsNothing,
        reason: 'the read-only session title is never used as the edit value',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rename dialog hints the CLI name when the agent has no slug name yet',
    (tester) async {
      const envelope =
          '{"id":"1","result":{"agents":['
          '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
          '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
          '"workspace_id":"wB",'
          '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
          ']}}';
      final runner = FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}]}}',
          );
        }
        return ok(envelope);
      });
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const ValueKey('agent-host-1-wB:p1')));
      await tester.pumpAndSettle();

      expect(find.text('Rename agent'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller?.text,
        isEmpty,
        reason: 'an unnamed agent starts with a blank field',
      );
      expect(
        field.decoration?.hintText,
        'copilot',
        reason: 'the CLI kind hints what to type',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'renders each host\'s agents under its own section header in the All '
    'view',
    (tester) async {
      final runnerA = FakeCommandRunner(_respond);
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      // Host section headers appear because more than one host is stored.
      expect(find.text('Host One'), findsOneWidget);
      expect(find.text('Host Two'), findsOneWidget);

      // Each host's agents and workspace labels render in its section —
      // including the same workspace id ("wA") existing on both hosts.
      expect(find.textContaining('Agent One'), findsOneWidget);
      expect(find.textContaining('Agent Bee'), findsOneWidget);
      expect(find.text('Project A'), findsOneWidget);
      expect(find.text('Project X'), findsOneWidget);

      // Host A's section (first in the stored order) sits above host B's.
      final headerATop = tester.getTopLeft(find.text('Host One')).dy;
      final headerBTop = tester.getTopLeft(find.text('Host Two')).dy;
      expect(headerATop, lessThan(headerBTop));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'isolates one host\'s failure: its section shows the error and retry, '
    'the other host still renders and drives the counts',
    (tester) async {
      final runnerA = FakeCommandRunner((_) => throw Exception('boom'));
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      // Host A failed: an inline error with its per-host retry button.
      expect(find.byType(ErrorMessageView), findsWidgets);
      expect(find.byKey(const ValueKey('host_retry_host-a')), findsOneWidget);

      // Host B is unaffected, and the global counts reflect it alone.
      expect(find.textContaining('Agent Bee'), findsOneWidget);
      expect(find.text('WAITING FOR YOU 1'), findsOneWidget);
      expect(find.text('WORKING 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a host that has connected before shows the lost-connection message, '
    'not the generic address/port one',
    (tester) async {
      final runnerA = FakeCommandRunner((_) => throw Exception('boom'));
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefEverConnected, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      // Both the agents-list error and the workspace-labels error rows show
      // it, since the fake runner fails every command.
      expect(find.textContaining('Lost the connection'), findsWidgets);
      expect(find.textContaining('address and port are correct'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the per-host retry button reloads that host', (tester) async {
    var fail = true;
    final runnerA = FakeCommandRunner((command) {
      if (fail) throw Exception('boom');
      return _respond(command);
    });
    final runnerB = FakeCommandRunner(_respondB);
    final clientA = HerdrClient(runnerA);
    final clientB = HerdrClient(runnerB);

    await tester.pumpWidget(
      _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('host_retry_host-a')), findsOneWidget);
    expect(find.textContaining('Agent One'), findsNothing);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('host_retry_host-a')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('host_retry_host-a')), findsNothing);
    expect(find.textContaining('Agent One'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('polls only the filtered host and shows its name in the chip', (
    tester,
  ) async {
    final runnerA = FakeCommandRunner(_respond);
    final runnerB = FakeCommandRunner(_respondB);
    final clientA = HerdrClient(runnerA);
    final clientB = HerdrClient(runnerB);

    await tester.pumpWidget(
      _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        filterHostId: 'host-a',
        pollInterval: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.textContaining('Agent One'), findsOneWidget);
    expect(find.textContaining('Agent Bee'), findsNothing);
    expect(runnerB.commands, isEmpty);

    // The chip carries the filtered host's name, not "All hosts". (The
    // name also heads the section, hence two matches.)
    expect(find.text('Host One'), findsWidgets);
    expect(find.text('All hosts'), findsNothing);
    expect(find.text('Host Two'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('greeting counts blocked agents across every host', (
    tester,
  ) async {
    final runnerA = FakeCommandRunner(_respond);
    final runnerB = FakeCommandRunner(_respondB);
    final clientA = HerdrClient(runnerA);
    final clientB = HerdrClient(runnerB);

    await tester.pumpWidget(
      _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
      ),
    );
    await tester.pump();
    await tester.pump();

    // One blocked agent on each host.
    expect(find.textContaining('2 agents', findRichText: true), findsOneWidget);
    expect(find.text('WAITING FOR YOU 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'FAB in the All view first asks which host to launch on, then opens the '
    'launch sheet against the picked host',
    (tester) async {
      final runnerA = FakeCommandRunner(_respond);
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('launch_host_host-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('launch_host_host-b')), findsOneWidget);
      expect(find.byType(LaunchAgentSheet), findsNothing);

      await tester.tap(find.byKey(const ValueKey('launch_host_host-b')));
      await tester.pumpAndSettle();

      expect(find.byType(LaunchAgentSheet), findsOneWidget);
      // The sheet's agent detection ran against host B, not host A.
      expect(runnerB.commands.any((c) => c.contains('command -v')), isTrue);
      expect(runnerA.commands.any((c) => c.contains('command -v')), isFalse);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a revision bump resets the host\'s bucket and refetches', (
    tester,
  ) async {
    const rebuiltEnvelope =
        '{"id":"1","result":{"agents":['
        '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
        '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
        '"workspace_id":"wA","name":"Agent New"}'
        ']}}';
    final oldClient = HerdrClient(FakeCommandRunner(_respond));
    final newClient = HerdrClient(
      FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wA","label":"Project A"}]}}',
          );
        }
        return ok(rebuiltEnvelope);
      }),
    );

    await tester.pumpWidget(_herdApp(client: oldClient));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Agent One'), findsOneWidget);

    // The host's connection was rebuilt (config edit): same hostId, bumped
    // revision, new client. The stale bucket must be dropped and refetched.
    await tester.pumpWidget(
      _herdApp(
        client: newClient,
        hosts: const [
          HerdHostRef(hostId: 'host-1', displayName: 'Work Mac', revision: 1),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Agent New'), findsOneWidget);
    expect(find.textContaining('Agent One'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed host is skipped by the immediately following tick', (
    tester,
  ) async {
    final runner = FakeCommandRunner((_) => throw Exception('boom'));
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      _herdApp(client: client, pollInterval: const Duration(seconds: 1)),
    );
    await tester.pump();
    await tester.pump();

    int listCalls() =>
        runner.commands.where((c) => c.contains("'agent' 'list'")).length;
    expect(listCalls(), 1, reason: 'the initial load ran (and failed)');

    // The next tick lands well inside the failure backoff window
    // (2 x pollInterval on the first failure), so the host is skipped. The
    // backoff schedule itself is unit-tested via [herdPollBackoff] — fake
    // timers advance test time, but DateTime.now() stays real.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(listCalls(), 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a network-change event clears a host\'s backoff so the next poll tick '
    'reloads it for real, without the event itself triggering a load',
    (tester) async {
      final runner = FakeCommandRunner((_) => throw Exception('boom'));
      final client = HerdrClient(runner);
      final networkChanges = StreamController<void>.broadcast();
      addTearDown(networkChanges.close);
      // 30s: the failStreak-1 backoff cap, matching the real "up to 30s"
      // window the issue complains about — a wide margin against the real
      // wall clock the "still armed" check below depends on (see the
      // linked doc comment on herdPollBackoff).
      const pollInterval = Duration(seconds: 30);
      const retryButton = ValueKey('host_retry_host-1');

      await tester.pumpWidget(
        _herdApp(
          client: client,
          pollInterval: pollInterval,
          networkChanges: networkChanges.stream,
        ),
      );
      await tester.pump();
      await tester.pump();

      int listCalls() =>
          runner.commands.where((c) => c.contains("'agent' 'list'")).length;
      expect(listCalls(), 1, reason: 'the initial load ran (and failed)');
      expect(find.byKey(retryButton), findsOneWidget);

      // One pollInterval later, the tick is still inside the failure
      // backoff window (2 x pollInterval on the first failure; nextPollAt
      // is compared against the real clock, which has barely moved), so the
      // host is skipped — proving the backoff is genuinely armed before the
      // signal is exercised at all.
      await tester.pump(pollInterval);
      await tester.pump();
      expect(listCalls(), 1);

      // Firing the signal alone must not itself issue a load — but it must
      // have run: the error (and its retry button) disappears immediately,
      // proving the handler executed within this pump rather than the
      // assertion below passing vacuously because it hadn't yet.
      networkChanges.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(retryButton), findsNothing);
      expect(listCalls(), 1, reason: 'but issued no load of its own');

      // With the backoff cleared, the next ordinary tick polls for real.
      await tester.pump(pollInterval);
      await tester.pump();
      expect(listCalls(), 2);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rebuilding with a different networkChanges stream resubscribes: the '
    'new controller is heard and the old one no longer acts',
    (tester) async {
      final runner = FakeCommandRunner((_) => throw Exception('boom'));
      final client = HerdrClient(runner);
      final oldController = StreamController<void>.broadcast();
      addTearDown(oldController.close);
      final newController = StreamController<void>.broadcast();
      addTearDown(newController.close);
      const pollInterval = Duration(seconds: 30);
      const retryButton = ValueKey('host_retry_host-1');

      await tester.pumpWidget(
        _herdApp(
          client: client,
          pollInterval: pollInterval,
          networkChanges: oldController.stream,
        ),
      );
      await tester.pump();
      await tester.pump();

      int listCalls() =>
          runner.commands.where((c) => c.contains("'agent' 'list'")).length;
      expect(listCalls(), 1, reason: 'the initial load ran (and failed)');
      expect(find.byKey(retryButton), findsOneWidget);

      // Rebuild with a genuinely different controller's stream — the shape
      // main.dart's own rebuild takes if the underlying signal were ever
      // swapped, and the only shape that can actually discriminate whether
      // didUpdateWidget's cancel-and-relisten ran: with the SAME controller,
      // an old subscription left listening would still hear a later event
      // fired on it (same source), passing either way.
      await tester.pumpWidget(
        _herdApp(
          client: client,
          pollInterval: pollInterval,
          networkChanges: newController.stream,
        ),
      );
      await tester.pump();

      // The discriminating half: an event on the OLD controller must no
      // longer be acted on — if the resubscribe branch were deleted (or a
      // no-op), the original subscription would still be listening to it and
      // would clear the backoff here.
      oldController.add(null);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(retryButton),
        findsOneWidget,
        reason: 'the old controller must have been unsubscribed',
      );
      expect(listCalls(), 1);

      // An event on the NEW controller must be heard.
      newController.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(retryButton), findsNothing);
      expect(listCalls(), 1, reason: 'the signal itself issues no load');

      await tester.pump(pollInterval);
      await tester.pump();
      expect(listCalls(), 2);

      await tester.pumpWidget(const SizedBox());
    },
  );

  group('HerdHostRef', () {
    test('equality and hashCode account for hostEverConnected', () {
      const a = HerdHostRef(hostId: 'h', displayName: 'H', revision: 0);
      const b = HerdHostRef(
        hostId: 'h',
        displayName: 'H',
        revision: 0,
        hostEverConnected: true,
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
      expect(
        a,
        equals(const HerdHostRef(hostId: 'h', displayName: 'H', revision: 0)),
      );
    });
  });

  group('herdPollBackoff', () {
    const interval = Duration(seconds: 2);

    test('doubles per consecutive failure', () {
      expect(herdPollBackoff(1, interval), const Duration(seconds: 4));
      expect(herdPollBackoff(2, interval), const Duration(seconds: 8));
      expect(herdPollBackoff(3, interval), const Duration(seconds: 16));
    });

    test('caps at 30 seconds', () {
      expect(herdPollBackoff(4, interval), const Duration(seconds: 30));
      expect(herdPollBackoff(5, interval), const Duration(seconds: 30));
    });

    test('clamps the exponent so a long streak cannot overflow', () {
      expect(
        herdPollBackoff(100, const Duration(milliseconds: 10)),
        const Duration(milliseconds: 320),
      );
    });
  });
}
