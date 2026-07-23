// Shared image-upload mechanics used by every agent's image-attachment
// capability: stage images under `<cwd>/.drover` (keeping the files inside
// the agent's own workspace so agents that gate file access by cwd don't
// trigger an out-of-workspace permission prompt) and git-ignore that
// directory so uploads can't be accidentally committed.
//
// This only extracts the upload/gitignore mechanics, which are identical
// across agents. Building the prompt text sent after upload — bare paths on
// their own lines for Claude, native `@path` mentions for Copilot — is left
// to each capability, since that syntax is agent-specific.

import 'dart:convert';

import '../herdr/command_runner.dart';
import '../herdr/herdr_client.dart';
import '../image/image_input.dart';
import '../models/agent_info.dart';

/// Uploads [images] into `<agent.cwd>/.drover`, writing a `.gitignore` that
/// excludes the whole directory, and returns the uploaded files' absolute
/// remote paths in upload order. [timestampMs] is injectable only so tests
/// get a deterministic filename.
Future<List<String>> uploadAgentImages(
  HerdrClient client,
  AgentInfo agent,
  List<PickedImage> images, {
  int? timestampMs,
}) async {
  final base = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
  final dir = '${agent.cwd}/.drover';
  await client.runner.run('command mkdir -p ${shQuote(dir)}');

  // Best-effort prune of stale prior uploads so `.drover` can't grow forever.
  // `-name 'img-*'` only targets our uploaded images (never the .gitignore),
  // and `-mtime +2` (older than two days) can never match the images being
  // uploaded right now. A prune failure must not break the upload, so swallow.
  try {
    await client.runner.run(
      'command find ${shQuote(dir)} -name ${shQuote('img-*')} '
      '-mtime +2 -delete',
    );
  } catch (_) {
    // best-effort: ignore prune failures
  }

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

  return paths;
}
