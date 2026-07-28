// Stub herdr backend: canned command responses and a small in-memory SFTP
// file map. Shared by dev previews, widget tests, and drover's production
// demo mode (main.dart's `_demoMode` branch) — see demo_backend.dart for the
// stateful fake the demo session runs against.
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
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    final contents = _files[path];
    if (contents == null) {
      return super.readFile(path, offset: offset, length: length);
    }
    final bytes = utf8.encode(contents);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
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

/// A canned `herdr --version` reply reporting [version] — moved here so any
/// responder answering `--version` (the production demo backend, or a
/// preview scenario like `herdr-too-old`) shares the same shape.
CommandResult versionResponse(String version) => ok('herdr $version\n');

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
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":[{"agent":"claude",'
      '"agent_status":"blocked","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"terminal_title_stripped":"OAuth callback を実装"}]}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(blockedPromptText);
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
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":[{"agent":"claude",'
      '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"terminal_title_stripped":"OAuth callback を実装"}]}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(idleWithModeText);
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

/// An assistant record whose content is [blocks] verbatim, letting a turn mix
/// text, thinking, and tool_use blocks the way Claude reports them.
String _nativeAssistant(List<Map<String, dynamic>> blocks) => jsonEncode({
  'type': 'assistant',
  'message': {'role': 'assistant', 'content': blocks},
});

Map<String, dynamic> _toolUse(String name, Map<String, dynamic> input) => {
  'type': 'tool_use',
  'name': name,
  'input': input,
};

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

const _assistantDiff = '''
And here's the change as a diff:

```diff
 Future<T> withRetry<T>(Future<T> Function() run, {int attempts = 3}) async {
-  for (var i = 0; ; i++) {
+  for (var i = 0; i < attempts; i++) {
     try {
       return await run();
-    } catch (_) {
-      if (i >= attempts - 1) rethrow;
+    } catch (_) {
+      if (i == attempts - 1) rethrow;
     }
   }
 }
```''';

const _editOld = '''  for (var i = 0; ; i++) {
    if (i >= attempts - 1) rethrow;
  }''';

const _editNew = '''  for (var i = 0; i < attempts; i++) {
    if (i == attempts - 1) rethrow;
  }''';

/// Canned Claude JSONL weaving thinking, tool_use, and text the way Claude
/// reports a turn: a prompt, a reply that thinks then reads/greps before its
/// Markdown overview, a fenced-code reply, a diff-block reply, and a final
/// reply that applies the fix via an Edit tool_use.
final nativeTranscriptJsonl =
    '${[
      _nativeLine('user', 'Can you summarize the auth module?'),
      _nativeAssistant([
        {'type': 'thinking', 'thinking': 'Let me read the auth controller and grep for refresh call '
            'sites before summarizing.'},
        _toolUse('Read', {'file_path': 'lib/auth/auth_controller.dart'}),
        _toolUse('Bash', {'command': 'grep -rn "refresh(" lib/auth', 'description': 'Find refresh call sites'}),
        {'type': 'text', 'text': _assistantOverview},
      ]),
      _nativeLine('user', 'Great — now show the retry helper.'),
      _nativeLine('assistant', _assistantCode),
      _nativeLine('user', 'Show me the fix as a diff.'),
      _nativeLine('assistant', _assistantDiff),
      _nativeAssistant([
        {'type': 'text', 'text': 'Applying the fix now.'},
        _toolUse('Edit', {'file_path': 'lib/auth/retry.dart', 'old_string': _editOld, 'new_string': _editNew}),
      ]),
    ].join('\n')}\n';

/// A stubbed Claude turn ending in an unanswered AskUserQuestion tool_use (a
/// single-select and a multi-select question, no matching tool_result), so the
/// agent screen auto-presents the answer sheet. Served under
/// [nativeTranscriptPath] via the `askuser` preview scenario. Submitting against
/// this stub errors (the injector's canned reads don't match) — the scenario is
/// for viewing the sheet, not driving a real submit.
final askUserTranscriptJsonl =
    '${[
      _nativeLine('user', 'Set up the deploy for me.'),
      _nativeAssistant([
        {'type': 'text', 'text': 'A couple of choices before I proceed.'},
        {
          'type': 'tool_use',
          'name': 'AskUserQuestion',
          'id': 'toolu_askuser_preview',
          'input': {
            'questions': [
              {
                'question': 'Which environment should I deploy to?',
                'header': 'Environment',
                'multiSelect': false,
                'options': [
                  {'label': 'Staging', 'description': 'Safe, resettable sandbox'},
                  {'label': 'Production', 'description': 'Live traffic — be careful'},
                ],
              },
              {
                'question': 'Which checks should run first?',
                'header': 'Pre-deploy checks',
                'multiSelect': true,
                'options': [
                  {'label': 'Unit tests'},
                  {'label': 'Integration tests'},
                  {'label': 'Lint'},
                ],
              },
            ],
          },
        },
      ]),
    ].join('\n')}\n';

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
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":[{"agent":"claude",'
      '"agent_status":"idle","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"terminal_title_stripped":"OAuth callback を実装",'
      '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
      '"value":"$_nativeSessionId"}}]}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(_nativeReadText);
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
