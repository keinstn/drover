import 'dart:convert';
import 'dart:typed_data';

import 'package:drover/src/agents/codex/codex_adapter.dart';
import 'package:drover/src/agents/codex/codex_images.dart';
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
  agent: 'codex',
  status: AgentStatus.idle,
  cwd: '/home/user/proj',
  focused: false,
);

void main() {
  group('CodexImageAttachmentCapability.send', () {
    test(
      'uploads bytes under deterministic names and returns remote paths',
      () async {
        final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
        final client = HerdrClient(runner);
        const capability = CodexImageAttachmentCapability();

        final paths = await capability.send(
          client,
          agent,
          images: [
            PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
            PickedImage(bytes: Uint8List.fromList([4, 5, 6]), extension: 'jpg'),
          ],
          deliver: (text) => client.prompt(agent.paneId, text),
          timestampMs: 42,
        );

        expect(paths, [
          '/home/user/proj/.drover/img-42-0.png',
          '/home/user/proj/.drover/img-42-1.jpg',
        ]);
        expect(runner.uploads[0].path, '/home/user/proj/.drover/img-42-0.png');
        expect(runner.uploads[0].bytes, [1, 2, 3]);
        expect(runner.uploads[1].path, '/home/user/proj/.drover/img-42-1.jpg');
        expect(runner.uploads[1].bytes, [4, 5, 6]);
      },
    );

    test('writes a .gitignore excluding the whole .drover dir', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = CodexImageAttachmentCapability();

      await capability.send(
        client,
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1]), extension: 'png'),
        ],
        deliver: (text) => client.prompt(agent.paneId, text),
        timestampMs: 7,
      );

      expect(runner.uploads.last.path, '/home/user/proj/.drover/.gitignore');
      expect(utf8.decode(runner.uploads.last.bytes), '*\n');
    });

    test('prompts with absolute paths only when caption is empty', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = CodexImageAttachmentCapability();

      await capability.send(
        client,
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
          PickedImage(bytes: Uint8List.fromList([4, 5, 6]), extension: 'jpg'),
        ],
        deliver: (text) => client.prompt(agent.paneId, text),
        timestampMs: 42,
      );

      expect(
        runner.commands,
        containsAllInOrder([
          "command mkdir -p '/home/user/proj/.drover'",
          "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
              "'/home/user/proj/.drover/img-42-0.png\n"
              "/home/user/proj/.drover/img-42-1.jpg'",
        ]),
      );
    });

    test(
      'prompts with trimmed caption above absolute paths when non-empty',
      () async {
        final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
        final client = HerdrClient(runner);
        const capability = CodexImageAttachmentCapability();

        await capability.send(
          client,
          agent,
          images: [
            PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
          ],
          deliver: (text) => client.prompt(agent.paneId, text),
          caption: 'look at this',
          timestampMs: 42,
        );

        expect(
          runner.commands,
          containsAllInOrder([
            "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
                "'look at this\n/home/user/proj/.drover/img-42-0.png'",
          ]),
        );
      },
    );

    test('trims trailing whitespace from caption before prepending', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const capability = CodexImageAttachmentCapability();

      await capability.send(
        client,
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1]), extension: 'png'),
        ],
        deliver: (text) => client.prompt(agent.paneId, text),
        caption: 'look at this   ',
        timestampMs: 7,
      );

      expect(
        runner.commands,
        containsAllInOrder([
          "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
              "'look at this\n/home/user/proj/.drover/img-7-0.png'",
        ]),
      );
    });

    test(
      'returns remote absolute paths even when cwd contains spaces',
      () async {
        final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
        final client = HerdrClient(runner);
        const capability = CodexImageAttachmentCapability();
        const spacedAgent = AgentInfo(
          paneId: 'wB:p1',
          workspaceId: 'wB',
          tabId: 'wB:t1',
          agent: 'codex',
          status: AgentStatus.idle,
          cwd: '/home/user/my proj',
          focused: false,
        );

        final paths = await capability.send(
          client,
          spacedAgent,
          images: [
            PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
          ],
          deliver: (text) => client.prompt(spacedAgent.paneId, text),
          caption: 'look at this',
          timestampMs: 42,
        );

        expect(paths, ['/home/user/my proj/.drover/img-42-0.png']);
        expect(
          runner.uploads[0].path,
          '/home/user/my proj/.drover/img-42-0.png',
        );
        expect(
          runner.commands,
          containsAllInOrder([
            "command mkdir -p '/home/user/my proj/.drover'",
            "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
                "'look at this\n/home/user/my proj/.drover/img-42-0.png'",
          ]),
        );
      },
    );
  });

  group('CodexImageAttachmentCapability with CodexAgentAdapter', () {
    test(
      'deliver callback is adapter-aware (uses CodexAgentAdapter.deliverPrompt)',
      () async {
        final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
        final client = HerdrClient(runner);
        const capability = CodexImageAttachmentCapability();

        await capability.send(
          client,
          agent,
          images: [
            PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
          ],
          deliver: (text) => const CodexAgentAdapter().deliverPrompt(
            client,
            agent.paneId,
            text,
          ),
          timestampMs: 42,
        );

        // CodexAgentAdapter uses the default deliverPrompt (client.prompt),
        // so we expect a plain agent prompt command with the absolute path.
        expect(
          runner.commands,
          containsAllInOrder([
            "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' "
                "'/home/user/proj/.drover/img-42-0.png'",
          ]),
        );
      },
    );
  });
}
