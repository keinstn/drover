import 'dart:convert';

import '../models/host_config.dart';
import 'command_runner.dart';

/// Thrown when the host OS cannot be positively identified.
class HostPlatformDetectionException implements Exception {
  HostPlatformDetectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _truncate(String s, [int max = 120]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// OS-specific command assembly for the herdr host, selected at connect time.
/// The host OS is a runtime property of the SSH target (not of the app), so
/// this is a runtime strategy, not conditional compilation.
abstract class HostPlatform {
  const HostPlatform();

  /// Positively classify the host OS, failing closed: an unrecognized host
  /// throws rather than defaulting to Unix, because sending POSIX quoting to
  /// the wrong shell corrupts every argument silently.
  ///
  /// - `uname -s` trimmed stdout 'Linux'/'Darwin'/`*BSD` (exit 0) → [UnixHostPlatform]
  /// - else `cmd.exe /c ver` exit 0 and stdout containing 'Windows' →
  ///   [WindowsHostPlatform] (works whether the default shell is cmd or
  ///   PowerShell)
  /// - else [HostPlatformDetectionException] with both probe outputs
  ///
  /// Transport errors from [runner] propagate untouched — a transient SSH
  /// failure must never classify the host.
  static Future<HostPlatform> detect(CommandRunner runner) async {
    final uname = await runner.run('uname -s');
    final kernel = uname.stdout.trim();
    if (uname.exitCode == 0 &&
        (kernel == 'Linux' || kernel == 'Darwin' || kernel.endsWith('BSD'))) {
      return const UnixHostPlatform();
    }
    final ver = await runner.run('cmd.exe /c ver');
    if (ver.exitCode == 0 && ver.stdout.contains('Windows')) {
      return const WindowsHostPlatform();
    }
    throw HostPlatformDetectionException(
      'Could not identify the host OS. '
      'uname -s: exit ${uname.exitCode}, '
      'stdout "${_truncate(kernel)}", '
      'stderr "${_truncate(uname.stderr.trim())}"; '
      'cmd.exe /c ver: exit ${ver.exitCode}, '
      'stdout "${_truncate(ver.stdout.trim())}"',
    );
  }

  /// Effective herdr binary for this OS given the configured value.
  String resolveHerdrBin(String configured);

  /// Full exec line invoking herdr with [args], each safely quoted for this
  /// OS's exec channel.
  String herdrCommand(String herdrBin, List<String> args);

  /// Exec line that prints each of [bins] that resolves on the host PATH,
  /// one name per line (names echoed verbatim so the caller can parse
  /// identically on both OSes).
  String detectAgentsCommand(List<String> bins);

  /// Exec line printing the absolute path of the first file matching
  /// [namePattern] at exactly [depth] levels below the search root, or
  /// nothing. The root is `$HOME/<homeFallback>` (POSIX) unless [envVar] is
  /// set on the host, in which case `$<envVar>` replaces the home fallback;
  /// [suffix] (if any) is appended below that root before searching.
  String findFileAtDepthCommand({
    String? envVar,
    required String homeFallback,
    String? suffix,
    required int depth,
    required String namePattern,
  });

  /// Exec line printing the absolute path of `<root>/<relativePath>` if it
  /// is an existing regular file, or nothing. Root resolution as in
  /// [findFileAtDepthCommand].
  String fileExistsCommand({
    String? envVar,
    required String homeFallback,
    required String relativePath,
  });

  /// Exec line creating [path] (and parents) if missing; success if it
  /// exists.
  String makeDirectoryCommand(String path);

  /// Exec line deleting files directly under [dir] matching [namePattern]
  /// whose mtime is older than [days] days. Callers treat this as
  /// best-effort.
  String pruneFilesOlderThanCommand(
    String dir,
    String namePattern, {
    required int days,
  });
}

class UnixHostPlatform extends HostPlatform {
  const UnixHostPlatform();

  @override
  String resolveHerdrBin(String configured) => configured;

  @override
  String herdrCommand(String herdrBin, List<String> args) =>
      buildHerdrCommand(herdrBin, args);

  @override
  String detectAgentsCommand(List<String> bins) {
    // `sh -lc` rather than `bash -lc`: `command -v` is POSIX, and some hosts
    // (e.g. Alpine) have no bash.
    final quoted = bins.map(shQuote).join(' ');
    final script =
        'for a in $quoted; do command -v "\$a" >/dev/null 2>&1 && echo "\$a"; done';
    return 'sh -lc ${shQuote(script)}';
  }

  @override
  String findFileAtDepthCommand({
    String? envVar,
    required String homeFallback,
    String? suffix,
    required int depth,
    required String namePattern,
  }) {
    final suffixPart = suffix == null ? '' : '/$suffix';
    if (envVar == null) {
      // Bare command (the default shell expands `$HOME`) with the pattern
      // shQuoted. The `envVar != null` branch below instead wraps in
      // `sh -lc` and double-quotes the pattern inside the script. The split
      // is historical — each branch reproduces its original call site
      // byte-for-byte so existing behavior and stubbed tests don't shift.
      return 'command find "\$HOME/$homeFallback$suffixPart" '
          '-mindepth $depth -maxdepth $depth -type f '
          '-name ${shQuote(namePattern)} -print -quit';
    }
    // `sh -lc` so login-shell env (e.g. CODEX_HOME) applies even when the
    // SSH account's default shell is non-POSIX (e.g. fish), and the
    // `${VAR:-fallback}` expansion syntax is guaranteed POSIX.
    final script =
        'command find "\${$envVar:-\$HOME/$homeFallback}$suffixPart" '
        '-mindepth $depth -maxdepth $depth -type f '
        '-name "$namePattern" -print -quit';
    return 'sh -lc ${shQuote(script)}';
  }

  @override
  String fileExistsCommand({
    String? envVar,
    required String homeFallback,
    required String relativePath,
  }) {
    final root = envVar == null
        ? '\$HOME/$homeFallback'
        : '\${$envVar:-\$HOME/$homeFallback}';
    // Always `sh -lc`, even without an env var: the `[ -f ]` test must run
    // under a POSIX shell (the SSH account's login shell can be fish).
    final script =
        'p="$root/$relativePath"; '
        'if [ -f "\$p" ]; then command printf "%s" "\$p"; fi';
    return 'sh -lc ${shQuote(script)}';
  }

  @override
  String makeDirectoryCommand(String path) =>
      'command mkdir -p ${shQuote(path)}';

  @override
  String pruneFilesOlderThanCommand(
    String dir,
    String namePattern, {
    required int days,
  }) =>
      'command find ${shQuote(dir)} -name ${shQuote(namePattern)} '
      '-mtime +$days -delete';
}

class WindowsHostPlatform extends HostPlatform {
  const WindowsHostPlatform();

  /// Forces UTF-8 native-command output (PowerShell 5.1 otherwise decodes via
  /// the console codepage, e.g. CP932 on Japanese Windows) and silences the
  /// progress stream, which PowerShell would otherwise emit as CLIXML noise
  /// on stderr when run over an SSH exec channel.
  static const _prelude =
      '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;'
      r'$OutputEncoding=[System.Text.Encoding]::UTF8;'
      r"$ProgressPreference='SilentlyContinue';";

  /// PowerShell single-quoted literal: only `'` needs escaping (doubled), so
  /// any Unicode and embedded newlines survive verbatim.
  static String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

  /// -EncodedCommand takes base64 of the UTF-16LE script bytes. Dart strings
  /// are UTF-16 code units already, so emit each unit low byte first.
  static String _encoded(String script) {
    final bytes = <int>[];
    for (final unit in script.codeUnits) {
      bytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return base64.encode(bytes);
  }

  /// -EncodedCommand bypasses cmd.exe parsing entirely — with cmd.exe as the
  /// default exec shell, POSIX quotes would reach herdr as literal characters.
  static String _wrap(String script) =>
      'powershell.exe -NoProfile -NonInteractive -EncodedCommand '
      '${_encoded(script)}';

  @override
  String resolveHerdrBin(String configured) {
    // The Unix default path is meaningless on Windows; a bare name resolves
    // via PATH. An explicitly configured value is honored as-is.
    return configured == kDefaultHerdrBin ? 'herdr' : configured;
  }

  @override
  String herdrCommand(String herdrBin, List<String> args) {
    // `exit $LASTEXITCODE`: powershell.exe does not reliably propagate a
    // native command's exit code on its own.
    final script =
        '$_prelude& ${_psQuote(herdrBin)} ${args.map(_psQuote).join(' ')};'
        r'exit $LASTEXITCODE';
    return _wrap(script);
  }

  @override
  String detectAgentsCommand(List<String> bins) {
    final script =
        '$_prelude'
        'foreach(\$a in @(${bins.map(_psQuote).join(',')}))'
        r'{if(Get-Command $a -ErrorAction SilentlyContinue){Write-Output $a}}';
    return _wrap(script);
  }

  /// PowerShell statements leaving the resolved search root in `$r`:
  /// `$env:<envVar>` when set, else `$env:USERPROFILE\<homeFallback>`, with
  /// [suffix] (if any) joined below.
  static String _psRoot(String? envVar, String homeFallback, String? suffix) {
    final fallback = 'Join-Path \$env:USERPROFILE ${_psQuote(homeFallback)}';
    var script = envVar == null
        ? '\$r=$fallback;'
        : 'if(\$env:$envVar){\$r=\$env:$envVar}else{\$r=$fallback};';
    if (suffix != null) {
      script += '\$r=Join-Path \$r ${_psQuote(suffix)};';
    }
    return script;
  }

  /// Prints `$p` as `/C:/Users/x` (backslashes → slashes, leading `/`) — the
  /// leading-slash drive form SFTP accepts and that the Dart callers'
  /// `startsWith('/')` validation and `/`-joins expect. `[Console]::Out.Write`
  /// rather than `Write-Output`: the callers match the emitted path exactly
  /// (`endsWith(...)`), and Write-Output's trailing CRLF would break them —
  /// this mirrors the Unix `printf "%s"` (caught live: the copilot validator
  /// rejected a found path solely for its trailing `\r\n`).
  static const _emitPosixPath =
      r"[Console]::Out.Write('/' + ($p -replace '\\','/'))";

  @override
  String findFileAtDepthCommand({
    String? envVar,
    required String homeFallback,
    String? suffix,
    required int depth,
    required String namePattern,
  }) {
    // Exact-depth match via a wildcard glob: depth N is N-1 intermediate
    // `*` segments below the root, e.g. depth 2 → `<root>\*\<pattern>`.
    final glob = '${'*\\' * (depth - 1)}$namePattern';
    final script =
        '$_prelude'
        '${_psRoot(envVar, homeFallback, suffix)}'
        '\$g=Join-Path \$r ${_psQuote(glob)};'
        // SilentlyContinue: a nonexistent root must yield empty stdout and
        // exit 0 (the caller treats empty as "no transcript", non-zero as
        // an error).
        '\$f=Get-ChildItem -Path \$g -File -ErrorAction SilentlyContinue'
        '|Select-Object -First 1;'
        'if(\$f){\$p=\$f.FullName;$_emitPosixPath}';
    return _wrap(script);
  }

  @override
  String fileExistsCommand({
    String? envVar,
    required String homeFallback,
    required String relativePath,
  }) {
    final script =
        '$_prelude'
        '${_psRoot(envVar, homeFallback, null)}'
        '\$p=Join-Path \$r ${_psQuote(relativePath)};'
        'if(Test-Path -LiteralPath \$p -PathType Leaf){$_emitPosixPath}';
    return _wrap(script);
  }

  @override
  String makeDirectoryCommand(String path) {
    // -Force makes this idempotent (no error when the directory exists).
    final script =
        '$_prelude'
        'New-Item -ItemType Directory -Force -Path ${_psQuote(path)}'
        '|Out-Null';
    return _wrap(script);
  }

  @override
  String pruneFilesOlderThanCommand(
    String dir,
    String namePattern, {
    required int days,
  }) {
    final script =
        '$_prelude'
        'Get-ChildItem -LiteralPath ${_psQuote(dir)} '
        '-Filter ${_psQuote(namePattern)} -File '
        '-ErrorAction SilentlyContinue'
        '|Where-Object {\$_.LastWriteTime -lt (Get-Date).AddDays(-$days)}'
        '|Remove-Item -ErrorAction SilentlyContinue';
    return _wrap(script);
  }
}
