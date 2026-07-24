import '../herdr/herdr_client.dart';
import '../herdr/herdr_version.dart';
import 'ssh_command_runner.dart';

/// A user-facing category for a caught error, used to pick a friendly
/// localized message. Ordered most-specific first.
enum AppErrorKind {
  /// The host presented a host key that doesn't match the pinned one.
  hostKeyMismatch,

  /// SSH authentication failed (bad key, passphrase, or user).
  sshAuth,

  /// The transport layer could not reach or stay connected to the host.
  hostConnection,

  /// The host's herdr is older than drover's minimum supported version.
  herdrVersionUnsupported,

  /// Anything else — including a herdr command that ran but reported failure.
  unknown,
}

/// Classifies an arbitrary caught [error] into an [AppErrorKind].
///
/// SSH failures reach the UI two ways: bare (from direct SFTP calls like
/// listDirectory/resolvePath) or wrapped as a [HerdrException] whose [cause]
/// is the original SSH exception (from herdr commands, which funnel through
/// `_exec`). Both are handled. A [HerdrException] with a non-null [cause]
/// means the transport threw (a real connectivity problem); one with no cause
/// means herdr ran and reported a failure (or returned junk) — treated as
/// [AppErrorKind.unknown] so we never tell the user to "check the connection"
/// for a command that actually reached the host.
AppErrorKind classifyError(Object error) {
  if (error is HerdrVersionUnsupportedException) {
    return AppErrorKind.herdrVersionUnsupported;
  }
  if (error is HerdrException) {
    final cause = error.cause;
    if (cause is SshHostKeyMismatchException) {
      return AppErrorKind.hostKeyMismatch;
    }
    if (cause is SshAuthException) return AppErrorKind.sshAuth;
    if (cause != null) return AppErrorKind.hostConnection;
    return AppErrorKind.unknown;
  }
  if (error is SshHostKeyMismatchException) return AppErrorKind.hostKeyMismatch;
  if (error is SshAuthException) return AppErrorKind.sshAuth;
  return AppErrorKind.unknown;
}

/// The raw technical detail for an error, cleaned of wrapper noise — shown in
/// the collapsible "Details" section, never as the primary message. Strips the
/// `HerdrException(code):` prefix by returning the inner message (or the
/// underlying cause's message when the transport threw).
String errorDetail(Object error) {
  // The headline already states found/minimum in full; a details expander
  // would only add this type's own Dart class name, not a real technical
  // cause the way SSH/herdr errors below have one.
  if (error is HerdrVersionUnsupportedException) return '';
  if (error is HerdrException) {
    final cause = error.cause;
    return cause != null ? cause.toString() : error.message;
  }
  return error.toString();
}
