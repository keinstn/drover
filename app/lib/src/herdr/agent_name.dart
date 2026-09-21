/// Agent names are herdr's, not ours.
///
/// `herdr agent start <name>` validates the name as `^[a-z][a-z0-9_-]{0,31}$`
/// (`invalid_agent_name`) and separately refuses one that a live agent already
/// holds (`agent_name_taken`). The format check runs *before* herdr resolves
/// the target pane (verified live on 0.9.1: a 33-character name and an
/// uppercase name were both rejected ahead of it), so a name drover derives
/// from something human — a workspace title, a Japanese folder name — fails
/// the whole start rather than degrading.
///
/// The slug is therefore lossy on purpose: it is a handle herdr will accept,
/// not a label anyone reads. Display text stays with `terminal_title_stripped`.
library;

import 'herdr_client.dart';

/// Reduces [base] to a name `herdr agent start` accepts.
String agentNameSlug(String base) {
  final slug = base
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceFirst(RegExp(r'^[^a-z]+'), '')
      .replaceFirst(RegExp(r'[-_]+$'), '');
  final trimmed = _truncate(slug, 32);
  return trimmed.isEmpty ? 'agent' : trimmed;
}

/// Starts an agent under a free, herdr-legal name derived from [base],
/// retrying while herdr reports the name taken. Returns the name used.
///
/// Collisions are only visible to herdr — another pane may have claimed the
/// name between our check and our start — so we let herdr be the judge and
/// walk a numeric suffix rather than pre-listing live agents.
Future<String> startAgentWithFreeName({
  required String base,
  required Future<void> Function(String name) start,
}) async {
  final slug = agentNameSlug(base);
  for (var attempt = 1; ; attempt++) {
    final suffix = attempt == 1 ? '' : '-$attempt';
    final name = attempt == 1
        ? slug
        : '${_truncate(slug, 32 - suffix.length)}$suffix';
    try {
      await start(name);
      return name;
    } on HerdrException catch (e) {
      if (e.code != 'agent_name_taken' || attempt >= 99) rethrow;
    }
  }
}

/// Cuts [value] to [max] characters, dropping any `-`/`_` the cut exposed.
String _truncate(String value, int max) =>
    (value.length <= max ? value : value.substring(0, max)).replaceFirst(
      RegExp(r'[-_]+$'),
      '',
    );
