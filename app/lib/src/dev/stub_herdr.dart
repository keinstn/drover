// Dev-only stub herdr backend for previews and widget tests. Not referenced
// by production `main.dart`, so it is excluded from release builds.
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
  StubCommandRunner(this._response);

  final CommandResult Function(String command) _response;
  final commands = <String>[];
  final uploads = <({String path, List<int> bytes})>[];

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

String jsonEncodeString(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}
