// Codex CLI's image-attachment convention: upload staged images under the
// agent's cwd and deliver their absolute paths as plain text, preceded by a
// trimmed caption on its own line when non-empty.
//
// Observed on Codex CLI 0.144.6: herdr is text-only and cannot synthesize
// Codex's native `--image`/clipboard attachments in an already-running TUI,
// but Codex successfully inspects an image whose absolute path is included in
// ordinary prompt text. Placing files under `<cwd>/.drover` keeps them inside
// the agent's workspace. The delivery format (one absolute path per line,
// optional caption above) is the same as Claude's verified path convention,
// but kept as a Codex-specific implementation to avoid cross-adapter coupling.

import '../../herdr/herdr_client.dart';
import '../../image/image_input.dart';
import '../../models/agent_info.dart';
import '../agent_capabilities.dart';
import '../agent_image_upload.dart';

class CodexImageAttachmentCapability implements ImageAttachmentCapability {
  const CodexImageAttachmentCapability();

  /// Uploads [images] into [agent]'s working directory and calls [deliver]
  /// with the composed prompt text: absolute paths (one per line), preceded
  /// by [caption] on its own line when non-empty. [deliver] is the
  /// adapter-aware delivery path so any adapter-level delivery behaviour
  /// (focus bracketing, etc.) applies uniformly to image turns.
  /// Returns the remote absolute paths in upload order.
  /// [timestampMs] is injectable only so tests get a deterministic filename.
  @override
  Future<List<String>> send(
    HerdrClient client,
    AgentInfo agent, {
    required List<PickedImage> images,
    required Future<void> Function(String) deliver,
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
    await deliver(text);
    return paths;
  }
}
