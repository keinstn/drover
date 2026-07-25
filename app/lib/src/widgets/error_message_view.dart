import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../herdr/herdr_version.dart';
import '../infra/app_error.dart';

/// The localized, human-friendly one-line message for [error]. Used directly
/// by transient toasts (which have no room for a details expander) and as the
/// headline of [ErrorMessageView]. For [AppErrorKind.unknown] it falls back to
/// the cleaned technical detail, since there is no better wording to offer.
///
/// [hostEverConnected] only affects [AppErrorKind.hostConnection]: it should
/// be true when the host this error came from has previously connected
/// successfully (e.g. its host-key fingerprint is already pinned), which
/// rules out "wrong address/port" by construction and lets the message point
/// at a dropped connection instead. Defaults to false — the existing generic
/// message is merely uninformative if shown wrongly, while the "lost
/// connection" message makes a claim that would be actively wrong for a host
/// that has never connected, so an un-updated caller should keep today's
/// behavior rather than opt into the new wording.
String errorHeadline(
  AppLocalizations l10n,
  Object error, {
  bool hostEverConnected = false,
}) {
  switch (classifyError(error)) {
    case AppErrorKind.hostKeyMismatch:
      return l10n.errorHostKeyMismatch;
    case AppErrorKind.sshAuth:
      return l10n.errorSshAuth;
    case AppErrorKind.hostConnection:
      return hostEverConnected
          ? l10n.errorHostConnectionLost
          : l10n.errorHostConnection;
    case AppErrorKind.herdrVersionUnsupported:
      final e = error as HerdrVersionUnsupportedException;
      return l10n.herdrVersionTooOld(e.found, e.minimum);
    case AppErrorKind.unknown:
      final detail = errorDetail(error);
      return detail.isEmpty ? l10n.errorGeneric : detail;
  }
}

/// A persistent error display: the localized [errorHeadline] plus a collapsible
/// "Details" section revealing the raw [errorDetail]. Drop-in for banner /
/// inline / future-builder error states (it does NOT include a Retry control —
/// callers keep their own). Toasts should use [errorHeadline] instead.
class ErrorMessageView extends StatefulWidget {
  const ErrorMessageView(
    this.error, {
    super.key,
    this.hostEverConnected = false,
  });
  final Object error;

  /// See [errorHeadline]'s parameter of the same name.
  final bool hostEverConnected;

  @override
  State<ErrorMessageView> createState() => _ErrorMessageViewState();
}

class _ErrorMessageViewState extends State<ErrorMessageView> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final headline = errorHeadline(
      l10n,
      widget.error,
      hostEverConnected: widget.hostEverConnected,
    );
    final detail = errorDetail(widget.error);
    // Only offer the expander when the detail adds something beyond the
    // headline (for unknown errors the headline already IS the detail).
    final hasExtraDetail = detail.isNotEmpty && detail != headline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(headline, style: TextStyle(color: theme.colorScheme.error)),
        if (hasExtraDetail) ...[
          TextButton(
            onPressed: () => setState(() => _showDetails = !_showDetails),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(l10n.errorDetailsLabel),
          ),
          if (_showDetails)
            SelectableText(
              detail,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
        ],
      ],
    );
  }
}
