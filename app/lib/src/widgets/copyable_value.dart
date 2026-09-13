import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';

/// A labelled, selectable monospace value with a copy button — for host
/// commands and codes the user has to get onto the host verbatim.
class CopyableValue extends StatelessWidget {
  const CopyableValue({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          droverLabelText(context, label),
          style: droverLabelStyle(context, fontSize: 10.5),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(
                  fontFamily: droverMonoFamily,
                  fontFeatures: droverMonoFeatures,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.commonCopy,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
          ],
        ),
      ],
    );
  }
}
