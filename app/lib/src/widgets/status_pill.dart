import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../i18n/status_label.dart';
import '../models/agent_info.dart';

/// A pill badge for an [AgentStatus]: a round dot plus the localized status
/// label, using the per-status chip colors from [DroverColors].
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.compact = false});

  final AgentStatus status;

  /// Denser variant: tightens the chip's horizontal padding.
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
        // The fill alone is a 10-12% wash over the page; the hairline is what
        // gives the chip an edge against a flat ink surface.
        border: Border.all(
          color: colors.statusDot(status).withValues(alpha: 0.34),
        ),
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
            droverLabelText(context, label),
            style: droverLabelStyle(
              context,
              fontSize: 9,
              color: colors.statusPillFg(status),
            ),
          ),
        ],
      ),
    );
  }
}
