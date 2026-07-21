import 'dart:convert';
import 'dart:typed_data';

import 'package:drover/src/agents/copilot/copilot_images.dart';
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
  agent: 'copilot',
  status: AgentStatus.idle,
  cwd: '/tmp/proj',
  focused: false,
);

void main() {
  group('CopilotImageAttachmentCapability.send', () {
    test(
      'uploads bytes for multiple images under deterministic names',
      () async {
        final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
        final client = HerdrClient(runner);
        const capability = CopilotImageAttachmentCapability();

        final paths = await capability.send(
          client,
          agent,
          images: [
            PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
            PickedImage(bytes: Uint8List.fromList([4, 5, 6]), extension: 'jpg'),
          ],
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
        expect(
          runner.commands.where(
            (c) => c == "command mkdir -p '/tmp/proj/.drover'",
          ),
          hasLength(1),
        );
      },
    );

    test('writes a .gitignore excluding the whole .drover dir', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = CopilotImageAttachmentCapability();

      await capability.send(
        client,
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1]), extension: 'png'),
        ],
        timestampMs: 7,
      );

      expect(runner.uploads.last.path, '/tmp/proj/.drover/.gitignore');
      expect(utf8.decode(runner.uploads.last.bytes), '*\n');
    });

    test(
      'prompts with relative @.drover mentions only when caption is empty',
      () async {
        final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
        final client = HerdrClient(runner);
        const capability = CopilotImageAttachmentCapability();

        await capability.send(
          client,
          agent,
          images: [
            PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
            PickedImage(bytes: Uint8List.fromList([4, 5, 6]), extension: 'jpg'),
          ],
          timestampMs: 42,
        );

        expect(
          runner.commands,
          containsAllInOrder([
            "command mkdir -p '/tmp/proj/.drover'",
            "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
                "'@.drover/img-42-0.png @.drover/img-42-1.jpg'",
          ]),
        );
      },
    );

    test('prompts with caption line above relative @.drover mentions when '
        'non-empty', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = CopilotImageAttachmentCapability();

      await capability.send(
        client,
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
        ],
        caption: 'look at this',
        timestampMs: 42,
      );

      expect(
        runner.commands,
        containsAllInOrder([
          "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
              "'look at this\n@.drover/img-42-0.png'",
        ]),
      );
    });

    test('uses relative mentions and absolute returned paths when cwd '
        'contains spaces', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = CopilotImageAttachmentCapability();
      const spacedAgent = AgentInfo(
        paneId: 'wB:p1',
        workspaceId: 'wB',
        tabId: 'wB:t1',
        agent: 'copilot',
        status: AgentStatus.idle,
        cwd: '/tmp/my proj',
        focused: false,
      );

      final paths = await capability.send(
        client,
        spacedAgent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
        ],
        caption: 'look at this',
        timestampMs: 42,
      );

      expect(paths, ['/tmp/my proj/.drover/img-42-0.png']);
      expect(runner.uploads[0].path, '/tmp/my proj/.drover/img-42-0.png');
      expect(
        runner.commands,
        containsAllInOrder([
          "command mkdir -p '/tmp/my proj/.drover'",
          "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
              "'look at this\n@.drover/img-42-0.png'",
        ]),
      );
    });
  });
}
