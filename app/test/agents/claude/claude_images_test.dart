import 'dart:convert';
import 'dart:typed_data';

import 'package:drover/src/agents/claude/claude_images.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/image/image_input.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner extends CommandRunner {
  final CommandResult Function(String command) _response;
  final commands = <String>[];
  final uploads = <({String path, List<int> bytes})>[];

  FakeCommandRunner(this._response);

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {
    uploads.add((path: remotePath, bytes: bytes));
  }

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

CommandResult ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

void main() {
  group('ClaudeImageAttachmentCapability.send', () {
    test('uploads bytes and prompts with caption and paths', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = ClaudeImageAttachmentCapability();
      const agent = AgentInfo(
        paneId: 'wB:p1',
        workspaceId: 'wB',
        tabId: 'wB:t1',
        agent: 'claude',
        status: AgentStatus.idle,
        cwd: '/tmp/proj',
        focused: false,
      );

      final paths = await capability.send(
        client,
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
          PickedImage(bytes: Uint8List.fromList([4, 5, 6]), extension: 'jpg'),
        ],
        deliver: (text) => client.prompt(agent.paneId, text),
        caption: 'look at this',
        timestampMs: 42,
      );

      expect(paths, [
        '/tmp/proj/.drover/img-42-0.png',
        '/tmp/proj/.drover/img-42-1.jpg',
      ]);
      expect(runner.uploads[0].path, '/tmp/proj/.drover/img-42-0.png');
      expect(runner.uploads[0].bytes, [1, 2, 3]);
      expect(runner.uploads[1].path, '/tmp/proj/.drover/img-42-1.jpg');
      expect(runner.uploads[1].bytes, [4, 5, 6]);
      expect(runner.uploads[2].path, '/tmp/proj/.drover/.gitignore');
      expect(utf8.decode(runner.uploads[2].bytes), '*\n');
      expect(
        runner.commands.where(
          (c) => c == "command mkdir -p '/tmp/proj/.drover'",
        ),
        hasLength(1),
      );
      expect(
        runner.commands,
        containsAllInOrder([
          "command mkdir -p '/tmp/proj/.drover'",
          "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
              "'look at this\n/tmp/proj/.drover/img-42-0.png\n"
              "/tmp/proj/.drover/img-42-1.jpg'",
        ]),
      );
    });
  });
}
