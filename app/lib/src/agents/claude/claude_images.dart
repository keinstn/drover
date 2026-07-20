// Claude Code's image-attachment convention: upload staged images under the
// agent's cwd (so Claude's file reads stay within the workspace and don't
// trigger an out-of-workspace permission prompt) and prompt it to read them
// by their absolute paths.

import '../../herdr/herdr_client.dart';
import '../../image/image_input.dart';
import '../../models/agent_info.dart';
import '../agent_capabilities.dart';
import '../agent_image_upload.dart';

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
    final paths = await uploadAgentImages(
      client,
      agent,
      images,
      timestampMs: timestampMs,
    );

    final trimmed = caption.trim();
    final text = trimmed.isEmpty
        ? paths.join('\n')
        : '${caption.trimRight()}\n${paths.join('\n')}';
    await client.prompt(agent.paneId, text);
    return paths;
  }
}
