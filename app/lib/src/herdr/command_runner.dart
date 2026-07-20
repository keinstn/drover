import '../models/remote_dir_entry.dart';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// SFTP metadata used to avoid transferring an unchanged remote file.
class RemoteFileStat {
  const RemoteFileStat({required this.size});

  final int size;
}

abstract class CommandRunner {
  Future<CommandResult> run(String command);

  /// Upload [bytes] to [remotePath] on the host, creating or truncating the
  /// file. The transport carries file uploads (SFTP) in addition to commands.
  Future<void> uploadFile(String remotePath, List<int> bytes);

  /// List the entries of the directory at [path]. The transport carries this
  /// (SFTP) in addition to commands.
  Future<List<RemoteDirEntry>> listDirectory(String path);

  /// Resolve [path] to an absolute path (realpath). Used to turn '.' into
  /// the home dir.
  Future<String> resolvePath(String path);

  /// Reads metadata for [path] without transferring the file contents.
  Future<RemoteFileStat> statFile(String path) =>
      Future.error(UnsupportedError('Remote file stats are unavailable'));

  /// Reads a byte range from [path]. Implementations should use SFTP where
  /// possible, rather than invoking a shell command.
  Future<List<int>> readFile(String path, {int offset = 0}) =>
      Future.error(UnsupportedError('Remote file reads are unavailable'));

  Future<void> dispose();
}

/// POSIX single-quote a string for safe use as a shell argument.
String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Build a herdr command line: `herdrBin` is left unquoted (so the remote
/// shell expands things like `~`), each arg in [args] is shell-quoted.
String buildHerdrCommand(String herdrBin, List<String> args) {
  return '$herdrBin ${args.map(shQuote).join(' ')}';
}
