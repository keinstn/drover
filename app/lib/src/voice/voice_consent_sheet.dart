import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// The version of the disclosure below. Bumping it is what re-asks: the
/// herd screen shows the sheet again to anyone who accepted an older one, so
/// a change to `voiceConsentBody` that describes new behaviour belongs with a
/// bump here, not on its own.
const kVoiceConsentVersion = 1;

/// Asks for consent before the first voice session, naming Google as the
/// third party the microphone audio and agent context go to — App Store
/// guideline 5.1.2(i) wants that disclosure *before* anything is sent.
///
/// Resolves true only on an explicit accept; a decline, a swipe-down and a
/// barrier tap all read as "no".
Future<bool> showVoiceConsentSheet(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    // The sheet paints its own panel; without this the 28-radius shell peeks
    // around its corners.
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _VoiceConsentSheet(),
  );
  return accepted ?? false;
}

class _VoiceConsentSheet extends StatelessWidget {
  const _VoiceConsentSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      // Only the disclosure scrolls; Accept and Decline stay pinned below it.
      // The copy is long enough to overflow a short screen, and a consent gate
      // whose buttons sit under the fold is not a consent gate.
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.voiceConsentTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.voiceConsentBody,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: const ValueKey('voice_consent_accept'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.voiceConsentAccept),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('voice_consent_decline'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.voiceConsentDecline),
            ),
          ],
        ),
      ),
    );
  }
}
