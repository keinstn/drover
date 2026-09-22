import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../widgets/sign_in_with_apple_button.dart';

/// Offers Sign in with Apple before a call, to an account that is still
/// anonymous.
///
/// Not a gate and not a pitch: the free credits are granted to a signed-in
/// account, so signing in is simply how an anonymous device gets any — and
/// it is what keeps them across a reinstall, whose fresh anonymous uid would
/// otherwise be a fresh empty wallet. Nothing is sold here, and declining
/// still opens the conversation — which is what "Not now" means.
///
/// Resolves true only on an explicit tap on the sign-in button; a decline, a
/// swipe-down and a barrier tap all read as "not now". The caller owns the
/// signing in itself, the same way the settings screen does.
Future<bool> showVoiceSignInSheet(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    // The sheet paints its own panel; without this the 28-radius shell peeks
    // around its corners.
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _VoiceSignInSheet(),
  );
  return accepted ?? false;
}

class _VoiceSignInSheet extends StatelessWidget {
  const _VoiceSignInSheet();

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
            // Only the copy scrolls, so both buttons stay reachable at an
            // accessibility text size — same shape as the consent sheet.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.voiceSignInTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.voiceSignInBody,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SignInWithAppleButton(
              key: const ValueKey('voice_sign_in_accept'),
              onPressed: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('voice_sign_in_decline'),
              // The consent sheet's own "Not now": the same escape, the same
              // words, so two sheets on the same path don't decline in two
              // different voices.
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.voiceConsentDecline),
            ),
          ],
        ),
      ),
    );
  }
}
