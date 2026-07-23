import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../i18n/status_label.dart';
import '../models/agent_info.dart';

/// A pill badge for an [AgentStatus]: a small color dot plus the localized
/// status label, using the per-status pill colors from [DroverColors].
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.compact = false});

  final AgentStatus status;

  /// Denser variant: tightens the pill's horizontal padding.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    final label = agentStatusLabel(AppLocalizations.of(context)!, status);
    final horizontal = compact ? 8.0 : 10.0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 4),
      decoration: BoxDecoration(
        color: colors.statusPillBg(status),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: colors.statusDot(status),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: colors.statusPillFg(status),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
