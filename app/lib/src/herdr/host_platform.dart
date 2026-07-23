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
}
