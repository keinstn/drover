// Drover Stage 0 spike: SSH 越しに herdr CLI を叩き、PoC の未知を実測する。
//
// 実測したいこと:
//   1. `agent read` の生出力がどれだけ読めるか(chat 整形ギャップ)
//   2. `agent prompt` でテキストを送信できるか
//   3. SSH 接続・コマンドのレイテンシ(ポーリング間隔の根拠)
//   4. `agent wait` が long-poll として使えるか(push-within-session の前身)
//
// 使い方:
//   fvm dart run tool/spike.dart --host <host> [opts] <command>
//
// Commands:
//   agents                                  エージェント一覧+状態
//   read <target> [--lines N] [--ansi]      出力の生読み
//   send <target> <text...>                 テキスト+Enter 送信
//   watch <target> [--status blocked] [--timeout 60000]
//                                           状態変化を long-poll で待つ
//   bench [N]                               agent list を N 回計測 (default 5)
//
// Options:
//   --host HOST        接続先 (env DROVER_HOST でも可)
//   --port PORT        default 22
//   --user USER        default: ローカルの $USER
//   --key PATH         秘密鍵 default ~/.ssh/id_ed25519
//   --passphrase P     鍵のパスフレーズ (必要な場合のみ)
//   --herdr-bin PATH   default ~/.local/bin/herdr (リモート shell が展開)

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

void usage() {
  final src = File(Platform.script.toFilePath()).readAsLinesSync();
  for (final line in src.takeWhile((l) => l.startsWith('//'))) {
    stdout.writeln(line.replaceFirst(RegExp('^// ?'), ''));
  }
}

String expandHome(String path) {
  final home = Platform.environment['HOME'] ?? '';
  return path.startsWith('~') ? path.replaceFirst('~', home) : path;
}

String shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

class Opts {
  String? host = Platform.environment['DROVER_HOST'];
  int port = 22;
  String user = Platform.environment['USER'] ?? 'root';
  String key = '~/.ssh/id_ed25519';
  String? passphrase;
  String herdrBin = '~/.local/bin/herdr';
  final rest = <String>[];
}

Opts parseArgs(List<String> args) {
  final o = Opts();
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('missing value for ${args[i]}');
        exit(2);
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--host':
        o.host = next();
      case '--port':
        o.port = int.parse(next());
      case '--user':
        o.user = next();
      case '--key':
        o.key = next();
      case '--passphrase':
        o.passphrase = next();
      case '--herdr-bin':
        o.herdrBin = next();
      case '--help' || '-h':
        usage();
        exit(0);
      default:
        o.rest.add(args[i]);
    }
  }
  return o;
}

class Remote {
  Remote(this.client, this.herdrBin);
  final SSHClient client;
  final String herdrBin;

  /// herdr サブコマンドを実行し (exitCode, stdout, stderr, elapsedMs) を返す。
  Future<(int, String, String, int)> herdr(
    List<String> args, {
    Duration? timeout,
  }) async {
    // herdrBin は ~ 展開のため quote しない。引数は quote する。
    final cmd = '$herdrBin ${args.map(shq).join(' ')}';
    final sw = Stopwatch()..start();
    final session = await client.execute(cmd);
    final outF = utf8.decodeStream(session.stdout);
    final errF = utf8.decodeStream(session.stderr);
    var done = session.done;
    if (timeout != null) done = done.timeout(timeout);
    await done;
    sw.stop();
    return (
      session.exitCode ?? -1,
      await outF,
      await errF,
      sw.elapsedMilliseconds,
    );
  }

  /// herdr の JSON 出力 ({"id":...,"result":{...}}) から result を取り出す。
  Future<(Map<String, dynamic>, int)> herdrJson(List<String> args) async {
    final (code, out, err, ms) = await herdr(args);
    if (code != 0) {
      stderr.writeln('herdr ${args.join(' ')} failed (exit $code)');
      if (err.isNotEmpty) stderr.writeln(err.trim());
      if (out.isNotEmpty) stderr.writeln(out.trim());
      exit(1);
    }
    final obj = jsonDecode(out) as Map<String, dynamic>;
    final result = obj['result'];
    if (result is! Map<String, dynamic>) {
      stderr.writeln('unexpected response shape: ${out.trim()}');
      exit(1);
    }
    return (result, ms);
  }
}

Future<void> main(List<String> args) async {
  final o = parseArgs(args);
  if (o.rest.isEmpty) {
    usage();
    exit(2);
  }
  if (o.host == null) {
    stderr.writeln('--host か DROVER_HOST が必要です');
    exit(2);
  }

  final keyFile = File(expandHome(o.key));
  if (!keyFile.existsSync()) {
    stderr.writeln('秘密鍵が見つかりません: ${keyFile.path}');
    exit(2);
  }
  final List<SSHKeyPair> identities;
  try {
    identities = SSHKeyPair.fromPem(keyFile.readAsStringSync(), o.passphrase);
  } catch (e) {
    stderr.writeln('鍵の読み込みに失敗: $e');
    stderr.writeln('(パスフレーズ付き鍵なら --passphrase を指定)');
    exit(2);
  }

  final connectSw = Stopwatch()..start();
  final SSHClient client;
  try {
    final socket = await SSHSocket.connect(
      o.host!,
      o.port,
      timeout: const Duration(seconds: 10),
    );
    client = SSHClient(socket, username: o.user, identities: identities);
    await client.authenticated;
  } catch (e) {
    stderr.writeln('SSH 接続失敗 (${o.user}@${o.host}:${o.port}): $e');
    exit(1);
  }
  connectSw.stop();
  stdout.writeln(
    '# connected ${o.user}@${o.host}:${o.port} in ${connectSw.elapsedMilliseconds}ms',
  );

  final r = Remote(client, o.herdrBin);
  final cmd = o.rest.first;
  final rest = o.rest.sublist(1);

  try {
    switch (cmd) {
      case 'agents':
        await cmdAgents(r);
      case 'read':
        await cmdRead(r, rest);
      case 'send':
        await cmdSend(r, rest);
      case 'watch':
        await cmdWatch(r, rest);
      case 'bench':
        await cmdBench(r, rest);
      default:
        stderr.writeln('unknown command: $cmd');
        usage();
        exit(2);
    }
  } finally {
    client.close();
  }
}

Future<void> cmdAgents(Remote r) async {
  final (result, ms) = await r.herdrJson(['agent', 'list']);
  final agents = (result['agents'] as List? ?? []).cast<Map<String, dynamic>>();
  stdout.writeln('# agent list in ${ms}ms — ${agents.length} agent(s)');
  if (agents.isEmpty) return;
  stdout.writeln('PANE      STATUS    AGENT      WS   FOCUSED  CWD');
  for (final a in agents) {
    final cwd = (a['foreground_cwd'] ?? a['cwd'] ?? '') as String;
    stdout.writeln(
      '${(a['pane_id'] ?? '').toString().padRight(10)}'
      '${(a['agent_status'] ?? '?').toString().padRight(10)}'
      '${(a['agent'] ?? '?').toString().padRight(11)}'
      '${(a['workspace_id'] ?? '').toString().padRight(5)}'
      '${(a['focused'] ?? false).toString().padRight(9)}'
      '${cwd.split('/').last}',
    );
  }
}

Future<void> cmdRead(Remote r, List<String> rest) async {
  if (rest.isEmpty) {
    stderr.writeln('read <target> [--lines N] [--ansi]');
    exit(2);
  }
  final target = rest.first;
  var lines = '120';
  var ansi = false;
  for (var i = 1; i < rest.length; i++) {
    if (rest[i] == '--lines' && i + 1 < rest.length) lines = rest[++i];
    if (rest[i] == '--ansi') ansi = true;
  }
  final (code, out, err, ms) = await r.herdr([
    'agent', 'read', target, //
    '--source', 'recent', '--lines', lines,
    '--format', ansi ? 'ansi' : 'text',
  ]);
  if (code != 0) {
    stderr.writeln('read failed (exit $code): ${err.trim()}');
    exit(1);
  }
  stdout.writeln('# read $target ($lines lines, ${out.length} bytes, ${ms}ms)');
  stdout.writeln('─' * 60);
  stdout.write(out);
  stdout.writeln('─' * 60);
}

Future<void> cmdSend(Remote r, List<String> rest) async {
  if (rest.length < 2) {
    stderr.writeln('send <target> <text...>');
    exit(2);
  }
  final target = rest.first;
  final text = rest.sublist(1).join(' ');

  final (code, _, err, ms) = await r.herdr(['agent', 'prompt', target, text]);
  if (code != 0) {
    stderr.writeln('prompt failed: ${err.trim()}');
    exit(1);
  }
  stdout.writeln('# prompted $target in ${ms}ms');
}

Future<void> cmdWatch(Remote r, List<String> rest) async {
  if (rest.isEmpty) {
    stderr.writeln('watch <target> [--status blocked] [--timeout 60000]');
    exit(2);
  }
  final target = rest.first;
  var status = 'blocked';
  var timeout = '60000';
  for (var i = 1; i < rest.length; i++) {
    if (rest[i] == '--status' && i + 1 < rest.length) status = rest[++i];
    if (rest[i] == '--timeout' && i + 1 < rest.length) timeout = rest[++i];
  }
  stdout.writeln('# waiting for $target → $status (timeout ${timeout}ms)…');
  final (code, out, err, ms) = await r.herdr([
    'agent',
    'wait',
    target,
    '--until',
    status,
    '--timeout',
    timeout,
  ], timeout: Duration(milliseconds: int.parse(timeout) + 10000));
  stdout.writeln('# returned in ${ms}ms (exit $code)');
  if (out.trim().isNotEmpty) stdout.writeln(out.trim());
  if (err.trim().isNotEmpty) stderr.writeln(err.trim());
}

Future<void> cmdBench(Remote r, List<String> rest) async {
  final n = rest.isEmpty ? 5 : int.parse(rest.first);
  final samples = <int>[];
  for (var i = 0; i < n; i++) {
    final (_, ms) = await r.herdrJson(['agent', 'list']);
    samples.add(ms);
    stdout.writeln('  run ${i + 1}: ${ms}ms');
  }
  samples.sort();
  final avg = samples.reduce((a, b) => a + b) / samples.length;
  stdout.writeln(
    '# agent list ×$n — min ${samples.first}ms / avg ${avg.toStringAsFixed(0)}ms / max ${samples.last}ms',
  );
}
