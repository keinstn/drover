import 'dart:convert';

import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/hc_client.dart';
import 'package:drover/src/herdr/herdr_backend.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Request = ({String method, Map<String, dynamic> params});

/// Answers each JSON-RPC line on stdin via [answer], which returns the
/// `result` value or throws an [RpcError] to reply with an error.
class FakeHcRunner extends CommandRunner {
  FakeHcRunner(this.answer);

  FakeHcRunner.raw(CommandResult Function(String stdin) raw)
    : answer = ((_) => null),
      _raw = raw;

  final Object? Function(Request request) answer;
  CommandResult Function(String stdin)? _raw;
  final commands = <String>[];
  final stdins = <String>[];

  /// Every request across every call, in order.
  final requests = <Request>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return const CommandResult(exitCode: 0, stdout: 'hc 0.1.17\n', stderr: '');
  }

  @override
  Future<CommandResult> runWithStdin(String command, String stdin) async {
    commands.add(command);
    stdins.add(stdin);
    if (_raw != null) return _raw!(stdin);
    final replies = <String>[];
    for (final line in const LineSplitter().convert(stdin)) {
      final req = jsonDecode(line) as Map<String, dynamic>;
      expect(req['jsonrpc'], '2.0');
      final r = (
        method: req['method'] as String,
        params: req['params'] as Map<String, dynamic>,
      );
      requests.add(r);
      try {
        replies.add(
          jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': answer(r)}),
        );
      } on RpcError catch (e) {
        replies.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': req['id'],
            'error': {
              'code': -32000,
              'message': e.message,
              'data': {'kind': ?e.kind, 'hint': 'h'},
            },
          }),
        );
      }
    }
    // Reverse to prove replies are matched by id, not position.
    return CommandResult(
      exitCode: 0,
      stdout: '${replies.reversed.join('\n')}\n',
      stderr: '',
    );
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

class RpcError implements Exception {
  RpcError(this.kind, this.message);
  final String? kind;
  final String message;
}

/// A terminal record shaped like the live-verified `terminal.list` item.
Map<String, dynamic> terminal({
  String address = 't3',
  Object? status = const {'app': 'claude-code', 'state': 'done'},
  Map<String, String> labels = const {},
  int turn = 1,
  String state = 'live',
  String title = 'Greeting',
  Map<String, dynamic>? foreground = const {
    'argv': ['claude'],
    'cwd': '/Users/x/proj/sub',
    'name': 'claude',
    'pid': 8266,
  },
}) => {
  'address': address,
  'argv': ['claude'],
  'cwd': '/Users/x/proj',
  'foreground': foreground,
  'labels': labels,
  'name': 'drover-probe',
  'state': state,
  'status': status,
  'title': title,
  'turn': turn,
};

const herdrAppDoc = {
  'value': {
    'spaces': [
      {'id': 's1', 'name': 'Work', 'folder': '/Users/x/work', 'tabs': []},
      {'id': 's2', 'name': '', 'folder': '/Users/x/proj/', 'tabs': []},
    ],
  },
  'version': 2,
};

HcClient clientFor(FakeHcRunner runner) => HcClient(runner);

Matcher throwsKind(String kind) =>
    throwsA(isA<HerdrException>().having((e) => e.code, 'code', kind));

void main() {
  test('backend is hc', () {
    expect(clientFor(FakeHcRunner((_) => null)).backend, HerdrBackend.hc);
  });

  test('version runs hc --version', () async {
    final runner = FakeHcRunner((_) => null);
    expect(await clientFor(runner).version(), 'hc 0.1.17\n');
    expect(runner.commands.single, "~/.local/bin/hc '--version'");
  });

  group('listAgents', () {
    Future<List<AgentInfo>> list(List<Map<String, dynamic>> terminals) =>
        clientFor(
          FakeHcRunner(
            (r) => r.method == 'terminal.list'
                ? {'hidden_finished': 0, 'terminals': terminals}
                : herdrAppDoc,
          ),
        ).listAgents();

    test('batches terminal.list and doc.get in one hc connect', () async {
      final runner = FakeHcRunner(
        (r) => r.method == 'terminal.list'
            ? {'terminals': <Object>[]}
            : herdrAppDoc,
      );
      await clientFor(runner).listAgents();
      expect(runner.commands.single, "~/.local/bin/hc 'connect'");
      expect(runner.stdins.single.split('\n'), hasLength(3)); // 2 + trailing
      expect(runner.requests.map((r) => r.method), [
        'terminal.list',
        'doc.get',
      ]);
      expect(runner.requests.map((r) => r.params), [
        isEmpty,
        {'name': 'herdr-app'},
      ]);
    });

    test('maps a terminal record to AgentInfo', () async {
      final agent = (await list([
        terminal(labels: {'herdr.space': 's1', 'herdr.tab': 'tb'}),
      ])).single;
      expect(agent.paneId, 't3');
      expect(agent.workspaceId, 's1');
      expect(agent.tabId, 'tb');
      expect(agent.agent, 'claude');
      expect(agent.name, 'drover-probe');
      expect(agent.cwd, '/Users/x/proj/sub');
      expect(agent.foregroundCwd, '/Users/x/proj/sub');
      expect(agent.focused, isFalse);
      expect(agent.agentSession, isNull);
      expect(agent.terminalTitle, 'Greeting');
      expect(agent.status, AgentStatus.done);
    });

    test('defaults missing labels, foreground and title', () async {
      final agent = (await list([
        terminal(
          foreground: null,
          title: '',
          status: {'app': '', 'state': 'idle'},
        ),
      ])).single;
      expect(agent.workspaceId, '');
      expect(agent.tabId, '');
      expect(agent.cwd, '/Users/x/proj');
      expect(agent.foregroundCwd, isNull);
      expect(agent.terminalTitle, isNull);
      expect(agent.agent, 'claude'); // argv basename
    });

    test('maps the app name', () async {
      final agents = await list([
        terminal(status: {'app': 'codex', 'state': 'idle'}),
        terminal(status: {'state': 'idle'}),
      ]);
      expect(agents.map((a) => a.agent), ['codex', 'claude']);
    });

    test('skips shells, remote mirrors and finished terminals', () async {
      final agents = await list([
        terminal(address: 't1', status: null),
        terminal(address: 'vps/t7'),
        terminal(address: 't2', state: 'finished'),
        terminal(address: 't3'),
      ]);
      expect(agents.map((a) => a.paneId), ['t3']);
    });

    test('maps status words and the herdr.seen rule', () async {
      final cases = <(String, String?, int, AgentStatus)>[
        ('working', null, 2, AgentStatus.working),
        ('working', '0', 2, AgentStatus.working),
        ('blocked', null, 2, AgentStatus.blocked),
        ('error', '5', 2, AgentStatus.blocked),
        ('idle', null, 2, AgentStatus.idle),
        ('done', null, 2, AgentStatus.done),
        ('done', '2', 2, AgentStatus.idle), // seen this turn
        ('done', '3', 2, AgentStatus.idle),
        ('idle', '1', 2, AgentStatus.done), // unseen turn
        ('done', '1', 2, AgentStatus.done),
        ('idle', 'junk', 2, AgentStatus.idle), // unparseable = no label
        ('starting', null, 2, AgentStatus.unknown),
      ];
      final agents = await list([
        for (final (i, (state, seen, turn, _)) in cases.indexed)
          terminal(
            address: 't$i',
            status: {'app': 'claude-code', 'state': state},
            labels: {'herdr.seen': ?seen},
            turn: turn,
          ),
      ]);
      expect(agents.map((a) => a.status), cases.map((c) => c.$4));
    });

    test('feeds the next listWorkspaces without another round trip', () async {
      final runner = FakeHcRunner(
        (r) => r.method == 'terminal.list'
            ? {'terminals': <Object>[]}
            : herdrAppDoc,
      );
      final client = clientFor(runner);
      await client.listAgents();
      expect((await client.listWorkspaces()).map((w) => w.workspaceId), [
        's1',
        's2',
      ]);
      expect(runner.stdins, hasLength(1));
      // Handed out once: the next call fetches fresh.
      await client.listWorkspaces();
      expect(runner.stdins, hasLength(2));
    });
  });

  group('listWorkspaces', () {
    test('labels by name, falling back to the folder basename', () async {
      final runner = FakeHcRunner((_) => herdrAppDoc);
      final ws = await clientFor(runner).listWorkspaces();
      expect(runner.requests.single.method, 'doc.get');
      expect(runner.requests.single.params, {'name': 'herdr-app'});
      expect(ws.map((w) => (w.workspaceId, w.label)), [
        ('s1', 'Work'),
        ('s2', 'proj'),
      ]);
    });

    test('a never-written doc means no workspaces', () async {
      final runner = FakeHcRunner((_) => {'value': null, 'version': 0});
      expect(await clientFor(runner).listWorkspaces(), isEmpty);
    });
  });

  group('getAgent', () {
    test('maps terminal.get', () async {
      final runner = FakeHcRunner((_) => terminal(address: 't9'));
      final agent = await clientFor(runner).getAgent('t9');
      expect(runner.requests.single.method, 'terminal.get');
      expect(runner.requests.single.params, {'terminal': 't9'});
      expect(agent.paneId, 't9');
    });

    test('throws not_agent for a plain shell', () async {
      final runner = FakeHcRunner((_) => terminal(status: null));
      await expectLater(
        clientFor(runner).getAgent('t3'),
        throwsKind('not_agent'),
      );
    });
  });

  test('readAgent reads terminal text', () async {
    final runner = FakeHcRunner(
      (_) => {'complete': true, 'how': 'stitched', 'text': 'hello'},
    );
    expect(await clientFor(runner).readAgent('t3', lines: 40), 'hello');
    expect(runner.requests.single.method, 'terminal.read');
    expect(runner.requests.single.params, {'terminal': 't3', 'lines': 40});
  });

  group('prompt', () {
    test('forces a bare option number', () async {
      final runner = FakeHcRunner((_) => {'started': true});
      await clientFor(runner).prompt('t3', '12');
      expect(runner.requests.single.method, 'terminal.send');
      expect(runner.requests.single.params, {
        'terminal': 't3',
        'text': '12',
        'force': true,
      });
    });

    test('sends free text unforced, so a blocked dialog refuses it', () async {
      final runner = FakeHcRunner((r) {
        if (r.params['force'] != true) {
          throw RpcError('blocked', 't3 is blocked (permission)');
        }
        return {};
      });
      await expectLater(
        clientFor(runner).prompt('t3', 'fix 1 bug'),
        throwsKind('blocked'),
      );
      expect(runner.requests.single.params, {
        'terminal': 't3',
        'text': 'fix 1 bug',
      });
    });
  });

  test('sendKeys passes the key name through', () async {
    final runner = FakeHcRunner((_) => {});
    await clientFor(runner).sendKeys('t3', 'esc');
    expect(runner.requests.single.method, 'terminal.keys');
    expect(runner.requests.single.params, {
      'terminal': 't3',
      'keys': ['esc'],
    });
  });

  group('sendPaneText', () {
    Future<List<Request>> send(String text) async {
      final runner = FakeHcRunner((_) => {});
      await clientFor(runner).sendPaneText('t3', text);
      return runner.requests;
    }

    test('shift+tab escape', () async {
      expect((await send('\x1b[Z')).single.params['keys'], ['shift+tab']);
    });

    test('focus reports are dropped', () async {
      expect(await send('\x1b[I'), isEmpty);
      expect(await send('\x1b[O'), isEmpty);
    });

    test('spells key-name text as one terminal.keys call', () async {
      final requests = await send("Hi 2,./;'`[]=-\\");
      expect(requests.single.method, 'terminal.keys');
      expect(requests.single.params['keys'], [
        'shift+h',
        'i',
        'space',
        '2',
        ',',
        '.',
        '/',
        ';',
        "'",
        '`',
        '[',
        ']',
        '=',
        '-',
        '\\',
      ]);
    });

    test('holds text hc cannot type until enter, then pastes it', () async {
      for (final text in ['hi!', 'こんにちは', 'a\nb']) {
        final runner = FakeHcRunner((_) => {});
        final client = clientFor(runner);
        await client.sendPaneText('t3', text);
        expect(runner.requests, isEmpty);
        await client.sendKeys('t3', 'enter');
        expect(runner.requests.single.method, 'terminal.send');
        expect(runner.requests.single.params, {
          'terminal': 't3',
          'text': text,
          'force': true,
        });
        // Consumed: the next enter is a key again.
        await client.sendKeys('t3', 'enter');
        expect(runner.requests.last.params['keys'], ['enter']);
      }
    });

    test('any other call on the pane drops the held text', () async {
      final calls = <String, Future<Object?> Function(HcClient c)>{
        'sendKeys down': (c) => c.sendKeys('t3', 'down'),
        'sendPaneText': (c) => c.sendPaneText('t3', '1'),
        'prompt': (c) => c.prompt('t3', '1'),
        'readAgent': (c) => c.readAgent('t3'),
        'getAgent': (c) => c.getAgent('t3'),
        'closeAgent': (c) => c.closeAgent('t3'),
        'markSeen': (c) => c.markSeen('t3'),
      };
      for (final MapEntry(:key, :value) in calls.entries) {
        final runner = FakeHcRunner(
          (r) => r.method == 'terminal.read' ? {'text': ''} : terminal(),
        );
        final client = clientFor(runner);
        await client.sendPaneText('t3', 'why?');
        await client.sendKeys('t4', 'enter'); // another pane: keeps it
        await value(client);
        await client.sendKeys('t3', 'enter');
        expect(
          runner.requests.where((r) => r.params['text'] == 'why?'),
          isEmpty,
          reason: key,
        );
        expect(runner.requests.last.params['keys'], ['enter'], reason: key);
      }
    });
  });

  test('closeAgent kills the terminal', () async {
    final runner = FakeHcRunner((_) => terminal(state: 'finished'));
    await clientFor(runner).closeAgent('t3');
    expect(runner.requests.single.method, 'terminal.kill');
    expect(runner.requests.single.params, {'terminal': 't3'});
  });

  group('markSeen', () {
    Future<List<Request>> mark(Map<String, String> labels, int turn) async {
      final runner = FakeHcRunner(
        (r) => r.method == 'terminal.get'
            ? terminal(labels: labels, turn: turn)
            : {},
      );
      await clientFor(runner).markSeen('t3');
      return runner.requests;
    }

    test('raises herdr.seen to the current turn', () async {
      final requests = await mark({'herdr.seen': '1'}, 3);
      expect(requests.map((r) => r.method), ['terminal.get', 'terminal.label']);
      expect(requests.last.params, {
        'terminal': 't3',
        'labels': {'herdr.seen': '3'},
      });
    });

    test('writes a missing label', () async {
      final requests = await mark({}, 0);
      expect(requests.last.params['labels'], {'herdr.seen': '0'});
    });

    test('never lowers or rewrites it', () async {
      expect((await mark({'herdr.seen': '3'}, 3)), hasLength(1));
      expect((await mark({'herdr.seen': '5'}, 3)), hasLength(1));
    });

    test('uses the last poll instead of a terminal.get', () async {
      final runner = FakeHcRunner(
        (r) => switch (r.method) {
          'terminal.list' => {
            'terminals': [
              terminal(address: 't1', labels: {'herdr.seen': '1'}, turn: 2),
              terminal(address: 't2', labels: {'herdr.seen': '2'}, turn: 2),
            ],
          },
          'doc.get' => herdrAppDoc,
          _ => {},
        },
      );
      final client = clientFor(runner);
      await client.listAgents();
      runner.requests.clear();
      await client.markSeen('t1');
      await client.markSeen('t1'); // cache raised: no second write
      await client.markSeen('t2'); // already seen
      expect(runner.requests.map((r) => r.method), ['terminal.label']);
      expect(runner.requests.single.params['labels'], {'herdr.seen': '2'});
    });
  });

  group('runAgent', () {
    test('runs through the login shell with labels and a slug name', () async {
      final runner = FakeHcRunner((_) => {'address': 't4'});
      final address = await clientFor(runner).runAgent(
        argv: ['claude', '--resume', 'a b'],
        cwd: '/p',
        spaceId: 's1',
        name: '  My Agent!! ${'x' * 40}',
      );
      expect(address, 't4');
      final params = runner.requests.single.params;
      expect(runner.requests.single.method, 'terminal.run');
      final argv = (params['argv'] as List).cast<String>();
      // `/bin/sh -c <fixed script> sh "$@"`: argv rides as positional args.
      expect(argv.take(2), ['/bin/sh', '-c']);
      expect(argv[2], isNot(contains('claude')));
      expect(argv.skip(3), ['sh', 'claude', '--resume', 'a b']);
      expect(params['cwd'], '/p');
      expect(params['labels'], {
        'herdr.space': 's1',
        'herdr.seen': '0',
        'drover.launched': '1',
      });
      expect(params['name'], 'my-agent-xxxxxxxxxxxxxxxxxxxxxxx');
      expect(params['name'], matches(RegExp(r'^[a-z0-9_-]{1,32}$')));
    });

    test('omits a blank name', () async {
      for (final name in [null, '  ']) {
        final runner = FakeHcRunner((_) => {'address': 't4'});
        await clientFor(
          runner,
        ).runAgent(argv: ['claude'], cwd: '/p', spaceId: 's1', name: name);
        expect(runner.requests.single.params.containsKey('name'), isFalse);
      }
    });

    test('retries once without the name when it is taken', () async {
      final runner = FakeHcRunner((r) {
        if (r.params.containsKey('name')) {
          throw RpcError('name_taken', 'name_taken');
        }
        return {'address': 't5'};
      });
      final address = await clientFor(
        runner,
      ).runAgent(argv: ['claude'], cwd: '/p', spaceId: 's1', name: 'a');
      expect(address, 't5');
      expect(runner.requests, hasLength(2));
      expect(runner.requests.last.params.containsKey('name'), isFalse);
    });

    test('a launched terminal without status is still an agent', () async {
      Object? argv;
      final runner = FakeHcRunner((r) {
        if (r.method == 'terminal.run') {
          argv = r.params['argv'];
          return {'address': 't4'};
        }
        final launched = terminal(
          address: 't4',
          status: null,
          foreground: null,
          labels: {'drover.launched': '1', 'herdr.space': 's1'},
        )..['argv'] = argv;
        return r.method == 'terminal.list'
            ? {
                'terminals': [launched, terminal(address: 't5', status: null)],
              }
            : r.method == 'terminal.get'
            ? launched
            : herdrAppDoc;
      });
      final client = clientFor(runner);
      await client.runAgent(argv: ['/opt/bin/aider'], cwd: '/p', spaceId: 's1');
      final agent = (await client.listAgents()).single;
      expect(agent.paneId, 't4');
      expect(agent.status, AgentStatus.unknown);
      expect(agent.agent, 'aider'); // argv basename, through the wrapper
      expect((await client.getAgent('t4')).agent, 'aider');
    });
  });

  group('errors', () {
    test('a JSON-RPC error maps to its kind', () async {
      final runner = FakeHcRunner(
        (_) => throw RpcError('blocked', 't6 is blocked (permission)'),
      );
      await expectLater(
        clientFor(runner).readAgent('t6'),
        throwsA(
          isA<HerdrException>()
              .having((e) => e.code, 'code', 'blocked')
              .having(
                (e) => e.message,
                'message',
                't6 is blocked (permission)',
              ),
        ),
      );
    });

    test('an error without a kind is unknown', () async {
      final runner = FakeHcRunner((_) => throw RpcError(null, 'boom'));
      await expectLater(
        clientFor(runner).readAgent('t6'),
        throwsKind('unknown'),
      );
    });

    test('a doc.get error still returns agents and drops the cache', () async {
      var docFails = false;
      final runner = FakeHcRunner((r) {
        if (r.method == 'doc.get') {
          if (docFails) throw RpcError('not_found', 'no doc');
          return herdrAppDoc;
        }
        return {
          'terminals': [
            terminal(labels: {'herdr.space': 's1'}),
          ],
        };
      });
      final client = clientFor(runner);
      await client.listAgents();
      docFails = true;
      final agents = await client.listAgents();
      expect(agents.single.workspaceId, 's1');
      // The first poll's list is not served stale: listWorkspaces fetches.
      await expectLater(client.listWorkspaces(), throwsKind('not_found'));
      expect(runner.stdins, hasLength(3));
    });

    test('a terminal.list error fails listAgents', () async {
      final runner = FakeHcRunner((r) {
        if (r.method == 'terminal.list') throw RpcError('internal', 'boom');
        return herdrAppDoc;
      });
      await expectLater(clientFor(runner).listAgents(), throwsKind('internal'));
    });

    for (final (name, result) in [
      (
        'non-zero exit',
        const CommandResult(exitCode: 1, stdout: '', stderr: 'x'),
      ),
      (
        'bad JSON',
        const CommandResult(exitCode: 0, stdout: 'nope\n', stderr: ''),
      ),
      (
        'missing reply',
        const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      ),
    ]) {
      test('$name is a transport error', () async {
        final runner = FakeHcRunner.raw((_) => result);
        await expectLater(
          clientFor(runner).readAgent('t3'),
          throwsKind('transport'),
        );
      });
    }

    test('a spawn failure is a transport error', () async {
      final runner = FakeHcRunner.raw((_) => throw StateError('ssh down'));
      await expectLater(
        clientFor(runner).readAgent('t3'),
        throwsKind('transport'),
      );
    });
  });

  group('unsupported on Herdr 2', () {
    final client = clientFor(FakeHcRunner((_) => {}));
    final calls = <String, Future<Object?> Function()>{
      'createWorkspace': () => client.createWorkspace(label: 'x'),
      'closeWorkspace': () => client.closeWorkspace('s1'),
      'renameWorkspace': () => client.renameWorkspace('s1', 'x'),
      'splitPane': () => client.splitPane(workspaceId: 's1', cwd: '/'),
      'startAgent': () =>
          client.startAgent(name: 'a', kind: 'claude', paneId: 't1'),
      'renameAgent': () => client.renameAgent('t1', 'x'),
      'pluginConfigDir': () => client.pluginConfigDir('p'),
    };
    for (final MapEntry(:key, :value) in calls.entries) {
      test(key, () => expectLater(value(), throwsKind('unsupported')));
    }

    test('findPlugin finds nothing', () async {
      expect(await client.findPlugin('drover-notify'), isNull);
    });
  });
}
