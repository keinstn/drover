import 'dart:convert';

import '../models/agent_info.dart';
import '../models/host_config.dart';
import 'command_runner.dart';

class HerdrException implements Exception {
  const HerdrException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'HerdrException($code): $message';
}

/// Talks to the `herdr` CLI over a [CommandRunner], parsing its single-line
/// JSON envelope responses.
class HerdrClient {
  HerdrClient(this._runner, {this.herdrBin = kDefaultHerdrBin});

  final CommandRunner _runner;
  final String herdrBin;

  Future<Map<String, dynamic>> _run(List<String> args) async {
    final command = buildHerdrCommand(herdrBin, args);
    final CommandResult result;
    try {
      result = await _runner.run(command);
    } catch (e) {
      throw HerdrException('transport', e.toString());
    }

    if (result.exitCode != 0) {
      throw HerdrException(
        'transport',
        'herdr ${args.join(' ')} failed (exit ${result.exitCode}): '
            '${result.stderr}',
      );
    }

    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(result.stdout) as Map<String, dynamic>;
    } catch (e) {
      throw HerdrException(
        'transport',
        'unparseable response: ${result.stdout}',
      );
    }

    final error = envelope['error'];
    if (error is Map<String, dynamic>) {
      throw HerdrException(
        error['code'] as String? ?? 'unknown',
        error['message'] as String? ?? 'unknown error',
      );
    }

    final res = envelope['result'];
    if (res is! Map<String, dynamic>) {
      throw HerdrException(
        'transport',
        'missing result field: ${result.stdout}',
      );
    }
    return res;
  }

  Future<List<AgentInfo>> listAgents() async {
    final result = await _run(['agent', 'list']);
    final agents = result['agents'];
    if (agents is! List) {
      throw const HerdrException('transport', 'missing agents field');
    }
    return agents
        .cast<Map<String, dynamic>>()
        .map(AgentInfo.fromJson)
        .toList();
  }

  Future<AgentInfo> getAgent(String target) async {
    final result = await _run(['agent', 'get', target]);
    final agent = result['agent'];
    if (agent is! Map<String, dynamic>) {
      throw const HerdrException('transport', 'missing agent field');
    }
    return AgentInfo.fromJson(agent);
  }

  Future<String> readAgent(String target, {int lines = 120}) async {
    final result = await _run([
      'agent',
      'read',
      target,
      '--source',
      'recent',
      '--lines',
      '$lines',
      '--format',
      'text',
    ]);
    final read = result['read'];
    if (read is! Map<String, dynamic> || read['text'] is! String) {
      throw const HerdrException('transport', 'missing read.text field');
    }
    return read['text'] as String;
  }

  Future<void> sendText(String paneId, String text) async {
    await _run(['agent', 'send', paneId, text]);
  }

  Future<void> sendKeys(String paneId, String key) async {
    await _run(['pane', 'send-keys', paneId, key]);
  }

  Future<void> prompt(String paneId, String text) async {
    await sendText(paneId, text);
    await sendKeys(paneId, 'enter');
  }
}
