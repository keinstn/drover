// Dev-only stub herdr backend for previews and widget tests. Not referenced
// by production `main.dart`, so it is excluded from release builds.
import 'dart:convert';

import '../herdr/command_runner.dart';
import '../models/remote_dir_entry.dart';

/// A small canned directory tree, keyed by absolute path, for previewing a
/// future directory browser without a real host.
const _stubDirTree = <String, List<RemoteDirEntry>>{
  '/home/dev': [
    RemoteDirEntry(name: 'proj', isDirectory: true),
    RemoteDirEntry(name: 'notes.txt', isDirectory: false),
  ],
  '/home/dev/proj': [
    RemoteDirEntry(name: 'src', isDirectory: true),
    RemoteDirEntry(name: 'README.md', isDirectory: false),
  ],
  '/home/dev/proj/src': [RemoteDirEntry(name: 'main.dart', isDirectory: false)],
};

class StubCommandRunner extends CommandRunner {
  StubCommandRunner(this._response, {Map<String, String>? files})
    : _files = files ?? const {};

  final CommandResult Function(String command) _response;

  /// Canned SFTP files, keyed by absolute path, served by [statFile]/[readFile]
  /// so native-transcript loading works without a real host.
  final Map<String, String> _files;
  final commands = <String>[];
  final uploads = <({String path, List<int> bytes})>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    final contents = _files[path];
    if (contents == null) return super.statFile(path);
    return RemoteFileStat(size: utf8.encode(contents).length);
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0}) async {
    final contents = _files[path];
    if (contents == null) return super.readFile(path, offset: offset);
    return utf8.encode(contents).sublist(offset);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {
    uploads.add((path: remotePath, bytes: bytes));
  }

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async {
    return _stubDirTree[path] ?? [];
  }

  @override
  Future<String> resolvePath(String path) async {
    return path == '.' ? '/home/dev' : path;
  }

  @override
  Future<void> dispose() async {}
}

CommandResult ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

const blockedPromptText =
    'Bash command\n'
    '\n'
    '  touch spike-test.txt\n'
    '  Create empty file spike-test.txt\n'
    '\n'
    ' Do you want to proceed?\n'
    ' ❯ 1. Yes\n'
    '   2. Yes, and always allow access to drover-spike-test/ from this\n'
    '      project\n'
    '   3. No\n'
    '\n'
    ' Esc to cancel · Tab to amend · ctrl+e to explain\n';

CommandResult blockedPromptResponse(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"claude",'
      '"agent_status":"blocked","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${jsonEncodeString(blockedPromptText)}}}}',
    );
  }
  return ok('{"id":"1","result":{}}');
}

const idleWithModeText =
    'Working on the task…\n'
    '  -- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)\n';

CommandResult idleWithModeResponse(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"claude",'
      '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${jsonEncodeString(idleWithModeText)}}}}',
    );
  }
  return ok('{"id":"1","result":{}}');
}

// A stubbed Claude native session so previews can show the chat-style history.
const _nativeSessionId = 'c7c50b87-4d4c-4a92-9396-2cfa4158612d';

/// Absolute path the loader's `find` is answered with; also the key under which
/// the canned JSONL is served via [StubCommandRunner]'s file map.
const nativeTranscriptPath =
    '/home/dev/.claude/projects/-tmp-proj/$_nativeSessionId.jsonl';

String _nativeLine(String type, String text) => jsonEncode({
  'type': type,
  'message': {
    'role': type,
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

const _assistantOverview = '''
## Auth module

The **auth module** handles sign-in and token refresh. Key pieces:

- `AuthController` — orchestrates the flow
- `TokenStore` — persists the refresh token
- *retry* on transient failures

Call `refresh()` before every request.''';

const _assistantCode = '''
Here's the retry helper:

```dart
Future<T> withRetry<T>(Future<T> Function() run, {int attempts = 3}) async {
  for (var i = 0; ; i++) {
    try {
      return await run();
    } catch (_) {
      if (i >= attempts - 1) rethrow;
    }
  }
}
```

It retries up to `attempts` times before giving up.''';

/// Canned Claude JSONL: a user prompt, a Markdown-rich reply, a follow-up
/// prompt, and a reply with a fenced code block.
final nativeTranscriptJsonl =
    '${[_nativeLine('user', 'Can you summarize the auth module?'), _nativeLine('assistant', _assistantOverview), _nativeLine('user', 'Great — now show the retry helper.'), _nativeLine('assistant', _assistantCode)].join('\n')}\n';

const _nativeReadText = 'It retries up to attempts times before giving up.\n';

CommandResult nativeHistoryResponse(String command) {
  if (command.startsWith('command find ')) {
    return ok('$nativeTranscriptPath\n');
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"claude",'
      '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three",'
      '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
      '"value":"$_nativeSessionId"}}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${jsonEncodeString(_nativeReadText)}}}}',
    );
  }
  return ok('{"id":"1","result":{}}');
}

String jsonEncodeString(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}
