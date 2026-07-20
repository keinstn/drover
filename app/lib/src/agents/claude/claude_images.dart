// Claude Code's image-attachment convention: upload staged images under the
// agent's cwd (so Claude's file reads stay within the workspace and don't
// trigger an out-of-workspace permission prompt) and prompt it to read them
// by their absolute paths.

import 'dart:convert';

import '../../herdr/command_runner.dart';
import '../../herdr/herdr_client.dart';
import '../../image/image_input.dart';
import '../../models/agent_info.dart';
import '../agent_capabilities.dart';

class ClaudeImageAttachmentCapability implements ImageAttachmentCapability {
  const ClaudeImageAttachmentCapability();

  /// Upload [images] into [agent]'s working directory and prompt the agent
  /// to read them by their absolute paths. Placing the files under the
  /// agent's cwd keeps Claude Code's file reads from triggering an
  /// out-of-workspace permission prompt (reads within the workspace are
  /// allowed). [caption], if non-empty, is sent on the line above the paths.
  /// Returns the remote paths in order. [timestampMs] is injectable only so
  /// tests get a deterministic filename.
  @override
  Future<List<String>> send(
    HerdrClient client,
    AgentInfo agent, {
    required List<PickedImage> images,
    String caption = '',
    int? timestampMs,
  }) async {
    final base = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final dir = '${agent.cwd}/.drover';
    await client.runner.run('command mkdir -p ${shQuote(dir)}');

    final paths = <String>[];
    for (var i = 0; i < images.length; i++) {
      final image = images[i];
      final path = '$dir/img-$base-$i.${image.extension}';
      await client.runner.uploadFile(path, image.bytes);
      paths.add(path);
    }

    // Mark the .drover dir git-ignored so uploaded images can't be
    // accidentally committed when cwd is a git repo. '*' ignores the dir's
    // whole contents, including this .gitignore itself.
    await client.runner.uploadFile('$dir/.gitignore', utf8.encode('*\n'));

    final trimmed = caption.trim();
    final text = trimmed.isEmpty
        ? paths.join('\n')
        : '${caption.trimRight()}\n${paths.join('\n')}';
    await client.prompt(agent.paneId, text);
    return paths;
  }
}
