// Single entrypoint for stubbed-backend UI previews (no SSH host needed) so
// screens can be screenshotted/inspected on a simulator.
//
//   just preview            # a gallery listing every screen x scenario
//   just preview launch     # boot one screen directly (marionette-friendly)
//
// Scenarios are orthogonal, via `--dart-define`, for direct single-screen
// boot:
//
//   just preview agent --dart-define=SCENARIO=blocked
//
// The gallery lists every scenario registered in [_scenariosByPreview] as
// its own tappable entry, so browsing them doesn't require relaunching.
//
// To add a screen, register a builder in [_previews] below — no new
// entrypoint file and no new justfile recipe. If it varies by scenario, list
// the scenario names in [_scenariosByPreview] too.
import 'dart:async';
import 'dart:math';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:record/record.dart';

import '../l10n/app_localizations.dart';
import '../src/app_theme.dart';
import '../src/demo/demo_herdr.dart';
import '../src/herdr/command_runner.dart';
import '../src/herdr/herdr_client.dart';
import '../src/herdr/herdr_version.dart';
import '../src/models/agent_info.dart';
import '../src/models/agent_preset.dart';
import '../src/infra/ssh_command_runner.dart';
import '../src/models/host_config.dart';
import '../src/models/plugin_info.dart';
import '../src/notifications/host_pairing.dart';
import '../src/notifications/notify_plugin_version.dart';
import '../src/screens/agent_screen.dart';
import '../src/screens/herd_screen.dart';
import '../src/screens/host_setup_screen.dart';
import '../src/screens/launch_agent_sheet.dart';
import '../src/screens/settings_screen.dart';
import '../src/voice/voice_audio.dart';
import '../src/voice/voice_drafts.dart';
import '../src/voice/voice_screen.dart';
import '../src/voice/voice_session.dart';
import '../src/voice/voice_tools.dart';
import '../src/voice/voice_transport.dart';
import '../src/widgets/error_message_view.dart';

const _scenario = String.fromEnvironment('SCENARIO', defaultValue: 'idle');

typedef PreviewBuilder = Widget Function(BuildContext context, String scenario);

/// Scenario names each screen responds to. Screens omitted here don't vary
/// by scenario, so the gallery shows a single entry for them.
const _scenariosByPreview = <String, List<String>>{
  'agent': ['idle', 'blocked', 'native', 'askuser'],
  'host-setup': ['idle', 'plugin-detected', 'auto-pair-failure'],
  'errors': ['en', 'ja'],
  'herd': ['idle', 'herdr-too-old'],
  'voice': [
    'live',
    'speaking',
    'draft',
    'ended',
    'start',
    'receipt',
    'error-receipt',
    'no-credits',
    'paid-interest',
    'paid-interest-done',
    'campaign-over',
  ],
};

HerdrClient _client(
  CommandResult Function(String) responder, {
  Map<String, String>? files,
}) => HerdrClient(StubCommandRunner(responder, files: files));

CommandResult _launchResponder(String command) {
  if (command.contains('command -v')) {
    // Report every preset as installed so the chip row shows its full
    // wrapped-layout width in the preview, not just a single chip.
    return ok(kAgentPresets.map((p) => p.bin).join('\n'));
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"drover"}]}}',
    );
  }
  if (command.contains("'workspace' 'create'")) {
    return ok(
      '{"id":"1","result":{"workspace":{"workspace_id":"wZ","label":"x"},'
      '"root_pane":{"pane_id":"wZ:p1"}}}',
    );
  }
  if (command.contains("'pane' 'list'")) {
    return ok('{"id":"1","result":{"panes":[{"pane_id":"wA:p1"}]}}');
  }
  if (command.contains("'pane' 'split'")) {
    return ok('{"id":"1","result":{"pane":{"pane_id":"wA:p2"}}}');
  }
  if (command.contains("'agent' 'start'")) {
    return ok('{"id":"1","result":{"type":"agent_started"}}');
  }
  return ok('{"id":"1","result":{}}');
}

// Two extra agents (besides the scenario's own wB:p1) with mixed types and
// statuses, so the bottom switcher bar is visible in the default agent preview.
const _barExtraAgents =
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA",'
    '"terminal_title_stripped":"データベース migration をレビュー"},'
    '{"agent":"codex","agent_status":"working","cwd":"/tmp/proj-c",'
    '"focused":false,"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC",'
    '"terminal_title_stripped":"型エラーを修正"}';

/// The scenario's own pane (wB:p1) as a single `agent list` entry.
String _currentAgent(String status) =>
    '{"agent":"claude","agent_status":"$status","cwd":"/tmp/proj",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
    '"terminal_title_stripped":"Implement the OAuth callback"}';

/// Wraps [base] so `agent list` returns wB:p1 (at [status]) plus the two extra
/// agents — making the switcher bar visible — while every other command
/// delegates to [base].
CommandResult Function(String) _withSwitcherBar(
  CommandResult Function(String) base,
  String status,
) => (command) {
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":['
      '${_currentAgent(status)},$_barExtraAgents]}}',
    );
  }
  return base(command);
};

const _herdListEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","terminal_title_stripped":"Implement the OAuth callback"},'
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p2","tab_id":"wA:t1",'
    '"workspace_id":"wA",'
    '"terminal_title_stripped":"データベース migration をレビュー"},'
    '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
    '"workspace_id":"wB",'
    '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
    ']}}';

const _herdAgentReadText =
    'Working on the task...\n'
    '-- INSERT -- auto mode on\n';

CommandResult _herdResponder(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'list'")) return ok(_herdListEnvelope);
  if (command.contains("'workspace' 'rename'") ||
      command.contains("'agent' 'rename'")) {
    return ok('{"id":"1","result":{"type":"ok"}}');
  }
  if (command.contains("'pane' 'close'")) {
    return ok('{"id":"1","result":{"type":"ok"}}');
  }
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"copilot",'
      '"agent_status":"working","cwd":"/tmp/proj-b","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(_herdAgentReadText);
  }
  return ok('{"id":"1","result":{}}');
}

/// Reports a herdr version below drover's minimum, so the version-warning
/// banner and blocked launch can be eyeballed (`SCENARIO=herdr-too-old`).
CommandResult _herdrTooOldResponder(String command) {
  if (command.contains("'--version'")) return versionResponse('0.7.0');
  return _herdResponder(command);
}

/// Registry of named previews. Add a screen = add an entry here.
final _previews = <String, PreviewBuilder>{
  'herd': (_, scenario) {
    final client = _client(
      scenario == 'herdr-too-old' ? _herdrTooOldResponder : _herdResponder,
    );
    return HerdScreen(
      hosts: const [
        HerdHostRef(hostId: 'stub-host-id', displayName: 'devbox', revision: 0),
      ],
      clientFor: (_) => client,
      filterHostId: null,
      onOpenHostSwitcher: () {},
      onOpenSettings: () {},
      pollInterval: const Duration(hours: 1),
    );
  },
  'agent': (_, scenario) => switch (scenario) {
    'native' => AgentScreen(
      client: _client(
        nativeHistoryResponse,
        files: {nativeTranscriptPath: nativeTranscriptJsonl},
      ),
      paneId: 'wB:p1',
      pollInterval: const Duration(hours: 1),
    ),
    'askuser' => AgentScreen(
      client: _client(
        nativeHistoryResponse,
        files: {nativeTranscriptPath: askUserTranscriptJsonl},
      ),
      paneId: 'wB:p1',
      pollInterval: const Duration(hours: 1),
    ),
    _ => AgentScreen(
      client: _client(
        scenario == 'blocked'
            ? _withSwitcherBar(blockedPromptResponse, 'blocked')
            : _withSwitcherBar(idleWithModeResponse, 'idle'),
      ),
      paneId: 'wB:p1',
      pollInterval: const Duration(hours: 1),
    ),
  },
  'launch': (_, _) => Scaffold(
    body: LaunchAgentSheet(
      client: _client(_launchResponder),
      existingCwds: const ['/home/dev/proj'],
    ),
  ),
  // A stubbed voice conversation, no Firebase/mic/network involved. Every
  // scenario scripts the same two finished transcripts on the transport's
  // receive() stream, then diverges: 'speaking' leaves an unfinished
  // assistant transcript pending (the glow should read as speaking), 'draft'
  // adds a pending message draft, 'ended' closes the stream, and 'start'
  // leaves the session idle — the screen as it looks before anyone taps
  // Start. 'receipt' ends the call on a clock wound forward, so the receipt
  // card shows a real length, and 'error-receipt' kills the same call
  // mid-sentence — the credit is spent either way, so the error line and
  // the receipt are both on screen. 'no-credits' and 'campaign-over' refuse
  // the mint the two ways the server can, which is how their cards get
  // looked at. 'paid-interest' and 'paid-interest-done' are the no-credits
  // refusal again for an account that already signed in — the offer to say
  // you would pay, before and after it has been recorded.
  'voice': (_, scenario) {
    final session = _voiceSession(scenario);
    // The screen only starts a call it can continue for free, so every
    // scripted scenario needs the tap a user would give it. Post-frame, not
    // here: start() notifies listeners, and this runs inside a build.
    if (scenario != 'start') {
      WidgetsBinding.instance.addPostFrameCallback((_) => session.start());
    }
    final paidInterest = _voicePaidInterest(scenario);
    return VoiceScreen(
      session: session,
      credits: _voiceCredits(scenario),
      // Non-null means "still anonymous", which is what puts the sign-in
      // action on the no-credits card. Null for the two paid-interest
      // scenarios, which are the same card for an account that already has
      // an Apple ID — the one case where the other action shows.
      onSignIn: paidInterest == null ? () async {} : null,
      paidInterest: paidInterest,
      // Records nothing: flipping the notifier is the whole of what the app
      // shows, and a preview has no backend to record into.
      onPaidInterest: paidInterest == null
          ? null
          : () async => paidInterest.value = true,
      agents: _voiceBarAgents,
      onOpenAgent: (_) {},
    );
  },
  'settings': (_, _) => const _SettingsPreview(),
  // Notification pairing: SCENARIO=idle (default) shows the manual dialog,
  // as if drover.notify were not linked on the host. SCENARIO=plugin-detected
  // shows the auto-pair confirmation → success path. SCENARIO=auto-pair-failure
  // confirms auto-pairing but has it fail, falling back to the manual dialog.
  'host-setup': (_, scenario) => HostSetupScreen(
    initial: const HostConfig(
      host: 'devbox.local',
      port: 22,
      user: 'dev',
      privateKeyPem:
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'stub-preview-key\n'
          '-----END OPENSSH PRIVATE KEY-----',
    ),
    onSubmit: (_) async {},
    onTest: (_) async => 'SSH connection succeeded (stubbed preview)',
    onCreatePairingCode: (_) async => const PairingCode(
      code: 'STUB-CODE-42',
      hostId: 'stub-host-id',
      completionUrl: 'https://drover.example/completePairing/stub',
    ),
    onDetectPlugin: (_) async =>
        scenario == 'plugin-detected' || scenario == 'auto-pair-failure'
        ? const PluginInfo(
            pluginId: 'drover.notify',
            enabled: true,
            pluginRoot: '/home/dev/drover-notify',
          )
        : null,
    onAutoPair: (config, plugin, pairing) async {
      if (scenario == 'auto-pair-failure') {
        throw Exception('node was not found on the host PATH (stubbed).');
      }
    },
  ),
  // Every ErrorMessageView kind side by side, so the localized headlines and
  // the collapsible details can be eyeballed. SCENARIO=ja renders the whole
  // list under the Japanese locale via a Localizations override.
  'errors': (context, scenario) => Localizations.override(
    context: context,
    locale: scenario == 'ja' ? const Locale('ja') : const Locale('en'),
    child: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Error states')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final (label, error) in _errorSamples) ...[
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ErrorMessageView(error),
              const Divider(height: 32),
            ],
          ],
        ),
      ),
    ),
  ),
};

/// One representative error per [errorHeadline] branch, in the two forms the
/// UI actually sees: bare (direct SFTP calls) and wrapped in a HerdrException
/// (herdr commands, which carry the transport error as `cause`).
final _errorSamples = <(String, Object)>[
  (
    'host-key mismatch (wrapped)',
    HerdrException(
      'transport',
      'wrapped',
      cause: SshHostKeyMismatchException(
        expected: 'SHA256:trusted-key-from-first-connect',
        observed: 'SHA256:different-key-presented-now',
      ),
    ),
  ),
  ('ssh auth (bare)', SshAuthException('Permission denied (publickey).')),
  (
    'host connection (wrapped socket error)',
    HerdrException(
      'transport',
      'sock',
      cause: Exception('SSHSocketError: Connection refused'),
    ),
  ),
  (
    'unknown (herdr command failed, no cause)',
    const HerdrException('command_failed', "workspace 'ws-9' not found"),
  ),
  (
    'herdr version unsupported',
    const HerdrVersionUnsupportedException(found: '0.7.0', minimum: '0.8.0'),
  ),
];

/// A scripted 0..1 level: bursts with a pause between them, so the glow has a
/// voice to follow with no mic and no engine. Deterministic, so a screenshot
/// of a given tick always comes back the same.
double _scriptedLevel(int tick) {
  final t = tick % 120; // a 6 s sentence at [_voiceTick]
  if (t > 84) return 0; // then the pause before the next one
  return ((sin(t * 0.7) * 0.5 + 0.5) * (sin(t * 0.13) * 0.35 + 0.6)).clamp(
    0.0,
    1.0,
  );
}

const _voiceTick = Duration(milliseconds: 50);

/// One PCM16 frame whose RMS is exactly [amplitude] — every sample sits at
/// the same magnitude, which is all [voiceLevelFromPcm16] measures.
Uint8List _scriptedFrame(double amplitude) {
  const samples = 480;
  final frame = Uint8List(samples * 2);
  final value = (amplitude.clamp(0.0, 1.0) * 32767).round();
  final data = ByteData.sublistView(frame);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, value, Endian.little);
  }
  return frame;
}

/// [VoiceMic] that grants permission and records nothing real, but streams a
/// scripted voice so the glow moves in a preview.
class _StubVoiceMic implements VoiceMic {
  @override
  Stream<RecordState> get state => const Stream.empty();

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async => Stream.periodic(
    _voiceTick,
    // Undo the gain the level takes on the way back out, so the scripted
    // level is what the glow actually sees.
    (tick) => _scriptedFrame(_scriptedLevel(tick) / kVoiceLevelGain),
  );

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// [VoiceSpeaker] that drops every byte it's handed, but reports a scripted
/// level so the `speaking` scenario shows the glow following the model — the
/// mic is gated for echo cancellation while the model talks.
class _StubVoiceSpeaker implements VoiceSpeaker {
  @override
  Stream<double> get level => Stream.periodic(_voiceTick, _scriptedLevel);

  @override
  Future<void> init() async {}

  @override
  void play(Uint8List pcm24k) {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() async {}
}

/// [VoiceTransport] whose `receive()` is scripted by [_voiceSession]; sends
/// are no-ops.
class _StubVoiceTransport implements VoiceTransport {
  _StubVoiceTransport(this._server);

  final StreamController<LiveServerResponse> _server;
  var _closed = false;

  @override
  Stream<LiveServerResponse> receive() => _server.stream;

  @override
  Future<void> sendAudio(Uint8List pcm16k) async {}

  @override
  Future<void> sendText(String text) async {}

  @override
  Future<void> sendToolResponse(List<FunctionResponse> responses) async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
  }
}

/// The balance behind the chip and the receipt: whatever the scenario's
/// story needs, since no wallet is read in a preview.
ValueNotifier<int?> _voiceCredits(String scenario) =>
    ValueNotifier(switch (scenario) {
      'receipt' || 'error-receipt' => 11,
      'no-credits' ||
      'campaign-over' ||
      'paid-interest' ||
      'paid-interest-done' => 0,
      _ => 12,
    });

/// Whether the paid-interest offer is on the no-credits card, and whether it
/// has been tapped. Null for every other scenario, which is what leaves the
/// sign-in action there instead — the two are the same slot.
///
/// Two scenarios rather than one so the recorded state can be screenshotted
/// without driving a tap first; tapping in 'paid-interest' reaches the same
/// place, since the notifier is what the card reads.
ValueNotifier<bool>? _voicePaidInterest(String scenario) => switch (scenario) {
  'paid-interest' => ValueNotifier(false),
  'paid-interest-done' => ValueNotifier(true),
  _ => null,
};

/// A [VoiceSession] wired to stubs (no Firebase, mic or speaker touched),
/// scripted per [scenario]: after ~800ms every scenario gets one finished
/// user transcript and one finished assistant transcript, then diverges —
/// see the 'voice' entry in [_previews] for what each scenario adds. Every
/// connect gets a fresh scripted stream, so Restart replays it; the draft
/// is added on the first connect only, so cards don't multiply.
VoiceSession _voiceSession(String scenario) {
  final drafts = VoiceDrafts();
  var connects = 0;
  // A clock the 'receipt' scenario winds forward once the call is live, so
  // the receipt reads as a call somebody actually had rather than as the
  // second the preview took to script itself. Everything else reads it as a
  // stopped clock, which is what a preview wants.
  final base = DateTime(2026, 1, 1, 9);
  var elapsed = Duration.zero;
  final session = VoiceSession(
    now: () => base.add(elapsed),
    connect: (_, _) async {
      // The two refusals the server can answer a mint with. Thrown from
      // connect, which is exactly where the real transport raises them.
      if (scenario == 'no-credits' ||
          scenario == 'paid-interest' ||
          scenario == 'paid-interest-done') {
        throw const VoiceOutOfCredits();
      }
      if (scenario == 'campaign-over') {
        throw const VoiceOutOfCredits(campaignOver: true);
      }
      final server = StreamController<LiveServerResponse>();
      _scriptVoice(server, scenario, drafts, first: connects++ == 0);
      return _StubVoiceTransport(server);
    },
    mic: _StubVoiceMic(),
    speaker: _StubVoiceSpeaker(),
    tools: [
      VoiceTool(
        name: 'list_agents',
        description: '',
        parameters: const {},
        run: (_) async => {'agents': []},
      ),
    ],
    drafts: drafts,
  );
  if (scenario == 'receipt' || scenario == 'error-receipt') {
    session.addListener(() {
      if (session.status == VoiceSessionStatus.live) {
        elapsed = const Duration(seconds: 298);
      }
    });
  }
  return session;
}

void _scriptVoice(
  StreamController<LiveServerResponse> server,
  String scenario,
  VoiceDrafts drafts, {
  required bool first,
}) {
  Future<void>.delayed(const Duration(milliseconds: 800), () {
    if (server.isClosed) return;
    server.add(
      LiveServerResponse(
        message: LiveServerContent(
          inputTranscription: const Transcription(
            text: 'Which agent is waiting for me?',
            finished: true,
          ),
        ),
      ),
    );
    server.add(
      LiveServerResponse(
        message: LiveServerContent(
          outputTranscription: const Transcription(
            text: 'Claude Code in drover is waiting on a question about tests.',
            finished: true,
          ),
        ),
      ),
    );
    switch (scenario) {
      case 'speaking':
        // The glow follows queued audio, not the transcript: a minute
        // of silence the stub speaker drops keeps it speaking.
        server.add(
          LiveServerResponse(
            message: LiveServerContent(
              modelTurn: Content('model', [
                InlineDataPart('audio/pcm;rate=24000', Uint8List(48000 * 60)),
              ]),
              outputTranscription: const Transcription(
                text: 'Let me check on that for you...',
                finished: false,
              ),
            ),
          ),
        );
      case 'draft' when first:
        drafts.add(
          const AgentInfo(
            paneId: 'wB:p1',
            workspaceId: 'wB',
            tabId: 'wB:t1',
            agent: 'claude',
            status: AgentStatus.blocked,
            cwd: '/tmp/proj',
            focused: false,
            terminalTitle: 'Implement the OAuth callback',
          ),
          'Please rerun the failing tests once more.',
        );
      case 'ended':
      case 'receipt':
        unawaited(server.close());
      // An error on the stream rather than a close: no resumption handle
      // was ever offered, so the session fails the call outright — which
      // is the mid-call death the receipt now has to survive.
      case 'error-receipt':
        server.addError(StateError('the connection dropped'));
    }
  });
}

/// The roster behind the voice screen's switcher bar, one agent per status
/// so every dot colour is on screen. Fixed: the preview has no poll.
final _voiceBarAgents = ValueNotifier<List<AgentInfo>>(const [
  AgentInfo(
    paneId: 'wA:p1',
    workspaceId: 'wA',
    tabId: 'wA:t1',
    agent: 'claude',
    status: AgentStatus.blocked,
    cwd: '/tmp/proj-a',
    focused: false,
    terminalTitle: 'Implement the OAuth callback',
  ),
  AgentInfo(
    paneId: 'wA:p2',
    workspaceId: 'wA',
    tabId: 'wA:t1',
    agent: 'copilot',
    status: AgentStatus.working,
    cwd: '/tmp/proj-a',
    focused: false,
    terminalTitle: 'データベース migration をレビュー',
  ),
  AgentInfo(
    paneId: 'wB:p1',
    workspaceId: 'wB',
    tabId: 'wB:t1',
    agent: 'codex',
    status: AgentStatus.idle,
    cwd: '/tmp/proj-b',
    focused: false,
    terminalTitle: 'Herd の session 表示を設計',
  ),
]);

void main() {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  const target = String.fromEnvironment('PREVIEW', defaultValue: 'gallery');
  final builder = _previews[target];

  runApp(
    MaterialApp(
      title: 'Drover preview',
      // Previews are the source for App Store screenshots, so the debug ribbon
      // has to go — same reason `main.dart` sets it.
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverLightTheme,
      darkTheme: droverDarkTheme,
      themeMode: ThemeMode.system,
      home: target == 'gallery'
          ? _PreviewGallery(previews: _previews, scenarios: _scenariosByPreview)
          : (builder != null
                ? Builder(builder: (ctx) => builder(ctx, _scenario))
                : _UnknownPreview(
                    target: target,
                    names: _previews.keys.toList(),
                  )),
    ),
  );
}

/// In-app list of every registered preview x scenario; tapping one pushes it.
class _PreviewGallery extends StatelessWidget {
  const _PreviewGallery({required this.previews, required this.scenarios});

  final Map<String, PreviewBuilder> previews;
  final Map<String, List<String>> scenarios;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drover previews')),
      body: ListView(
        children: [
          for (final name in previews.keys)
            for (final scenario in scenarios[name] ?? const ['none'])
              ListTile(
                key: ValueKey('preview_${name}_$scenario'),
                leading: const Icon(Icons.visibility),
                title: Text(
                  scenarios.containsKey(name) ? '$name ($scenario)' : name,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (ctx) => previews[name]!(ctx, scenario),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Backs the 'settings' preview with local state so the theme/language
/// sheets are actually exercisable — [SettingsScreen] itself is stateless.
class _SettingsPreview extends StatefulWidget {
  const _SettingsPreview();

  @override
  State<_SettingsPreview> createState() => _SettingsPreviewState();
}

class _SettingsPreviewState extends State<_SettingsPreview> {
  ThemeMode _themeMode = ThemeMode.system;
  Locale? _locale;
  bool _notifyOnBlocked = true;
  bool _notifyOnDone = true;

  // Held in a field, not built in [build]: a fresh future on every rebuild
  // would drop the row back to its empty state on each switch toggle.
  final List<Future<StaleNotifyPlugin?>> _staleNotifyPlugins = [
    Future.value(
      const StaleNotifyPlugin(
        hostName: 'dev@stub-host',
        installedVersion: '0.0.1',
        herdrBin: kDefaultHerdrBin,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SettingsScreen(
      themeMode: _themeMode,
      locale: _locale,
      notifyOnBlocked: _notifyOnBlocked,
      notifyOnDone: _notifyOnDone,
      onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      onLocaleChanged: (locale) => setState(() => _locale = locale),
      onNotifyOnBlockedChanged: (value) =>
          setState(() => _notifyOnBlocked = value),
      onNotifyOnDoneChanged: (value) => setState(() => _notifyOnDone = value),
      voiceAssistantEnabled: true,
      onVoiceAssistantChanged: (_) {},
      appleSignedIn: false,
      onSignInWithApple: () async {},
      onDeleteAccount: () async {},
      onManageHosts: () {},
      hasHosts: false,
      appVersion: '0.0.0-preview (0)',
      staleNotifyPlugins: _staleNotifyPlugins,
    );
  }
}

class _UnknownPreview extends StatelessWidget {
  const _UnknownPreview({required this.target, required this.names});

  final String target;
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(
          'Unknown preview "$target".\nAvailable: ${names.join(', ')}',
        ),
      ),
    );
  }
}
