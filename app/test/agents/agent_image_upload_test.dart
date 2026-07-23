import 'dart:typed_data';

import 'package:drover/src/agents/agent_image_upload.dart';
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

const agent = AgentInfo(
  paneId: 'wB:p1',
  workspaceId: 'wB',
  tabId: 'wB:t1',
  agent: 'claude',
  status: AgentStatus.idle,
  cwd: '/tmp/proj',
  focused: false,
);

void main() {
  group('uploadAgentImages', () {
    test('prunes stale prior uploads under .drover', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);

      await uploadAgentImages(client, agent, [
        PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
      ], timestampMs: 42);

      expect(
        runner.commands.where(
          (c) =>
              c ==
              "command find '/tmp/proj/.drover' -name 'img-*' "
                  "-mtime +2 -delete",
        ),
        hasLength(1),
      );
    });
  });
}
