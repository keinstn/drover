// GitHub Copilot CLI's image-attachment convention: upload staged images
// under the agent's cwd (the same `<cwd>/.drover` staging area
// agent_image_upload.dart uses for every agent) and prompt Copilot to read
// them via native `@path` mentions rather than a bare path.
//
// Live-observed on Copilot CLI 1.0.72 (see docs/herdr-notes.md): a *relative*
// mention (`@.drover/image.png`) is parsed as a native attachment and
// recorded in `user.message.attachments` with the correct absolute path,
// even when the agent's cwd contains spaces. An *absolute*-path mention
// (`@/abs/path with spaces/image.png`) is not parsed at all when the path
// contains a space, so drover mentions uploads by their path relative to
// cwd rather than by the absolute path returned from upload.

import '../../herdr/herdr_client.dart';
import '../../image/image_input.dart';
import '../../models/agent_info.dart';
import '../agent_capabilities.dart';
import '../agent_image_upload.dart';

class CopilotImageAttachmentCapability implements ImageAttachmentCapability {
  const CopilotImageAttachmentCapability();

  /// Upload [images] into [agent]'s working directory and prompt Copilot to
  /// attach them by `@.drover/<filename>` mention, relative to the agent's
  /// cwd. Placing the files under the agent's cwd (in `.drover`, alongside a
  /// `.gitignore` excluding it) keeps the upload out of an out-of-workspace
  /// permission prompt, matching Claude Code's convention. Mentions are
  /// relative rather than absolute because live Copilot CLI fails to parse
  /// an absolute-path mention whose path contains a space (see
  /// docs/herdr-notes.md), while relative mentions resolve correctly
  /// regardless. [caption], if non-empty, is sent on the line above the
  /// mentions. Returns the uploaded files' absolute remote paths in order,
  /// unaffected by the relative mention syntax used in the prompt.
  /// [timestampMs] is injectable only so tests get a deterministic filename.
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

    final mentions = paths
        .map((path) => '@.drover/${_filenameOf(path)}')
        .join(' ');
    final trimmed = caption.trim();
    final text = trimmed.isEmpty
        ? mentions
        : '${caption.trimRight()}\n$mentions';
    await client.prompt(agent.paneId, text);
    return paths;
  }
}

/// Extracts the final path segment from an uploaded image's absolute remote
/// [path] for use in a `.drover`-relative mention. [path] always comes from
/// [uploadAgentImages], which only ever produces
/// `<agent.cwd>/.drover/img-<ts>-<i>.<ext>` — this just guards against that
/// invariant being violated rather than accepting arbitrary path traversal.
String _filenameOf(String path) {
  final name = path.split('/').last;
  if (name.isEmpty || name == '.' || name == '..') {
    throw StateError('Unexpected uploaded image path: $path');
  }
  return name;
}
