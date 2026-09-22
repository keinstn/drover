import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';

/// The Sign in with Apple button, built to Apple's Human Interface
/// Guidelines for a custom button
/// (https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple).
///
/// App Review evaluates every custom Sign in with Apple button, so the
/// numbers here are Apple's, not taste: the title is one of the three titles
/// they permit, the fill and the mark are black-on-light / white-on-dark and
/// nothing else, the button is at least 140x30pt, the title's font size is
/// 43% of the button's height, and the title keeps at least 8% of the
/// button's width clear of the trailing edge. The one thing callers owe it is
/// a margin of at least a tenth of its height.
///
/// One widget for all three places that offer signing in — the settings row,
/// the pre-call sheet, the out-of-credits card — because a second
/// implementation is a second thing to get rejected.
class SignInWithAppleButton extends StatelessWidget {
  const SignInWithAppleButton({super.key, required this.onPressed});

  /// Null while a sign-in is in flight, which is also what greys the button.
  final VoidCallback? onPressed;

  /// Apple's floor is 30pt; 44 is the tap target the rest of the app uses.
  static const double baseHeight = 44;

  /// Apple's floor, and the width the button falls back to where nothing
  /// stretches it.
  static const double minWidth = 140;

  /// Apple's proportion: the title is 43% of the button's height, or, read
  /// the other way, the button is 233% of the title.
  static const double titleHeightRatio = 0.43;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Apple allows exactly two palettes and says which background each one
    // is for: black on white or light, white on dark.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? Colors.white : Colors.black;
    final foreground = dark ? Colors.black : Colors.white;
    // The button grows with the text size rather than clipping its title —
    // and growing the box with the title is also the only way the 43%
    // proportion survives an accessibility text size.
    final height = MediaQuery.textScalerOf(context).scale(baseHeight);
    final fontSize = height * titleHeightRatio;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        // Disabled wears the same two colours: Material would grey the fill,
        // and Apple permits black or white and nothing in between. Nothing
        // is lost — the button is only disabled for the instant between the
        // tap and Apple's own sheet appearing.
        disabledBackgroundColor: background,
        disabledForegroundColor: foreground,
        // Apple lets the corner radius match the rest of the interface.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(droverRadiusSmall),
        ),
        minimumSize: Size(minWidth, height),
        // Apple's minimums are in points, so the button can't be allowed to
        // shrink with the platform's density the way an ordinary one does.
        visualDensity: VisualDensity.standard,
        // 12 clears 8% of the narrowest button Apple permits (140), and the
        // title is centred, so a wider button only ever has more room.
        padding: const EdgeInsets.symmetric(horizontal: 12),
        // The painted button is already 44 tall, so nothing needs padding
        // out to a tap target — and padding it out would break the margin
        // the caller leaves around it.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // ponytail: Apple's own artwork, which we are told to use and
          // never redraw, is a download that would have to land in
          // app/assets and pubspec.yaml — outside this change. Material's
          // apple glyph stands in until it does, sized by eye against the
          // system button rather than by Apple's "match the button height",
          // which is a rule about their file's built-in padding and would
          // make this glyph enormous.
          Icon(Icons.apple, size: height * 0.45, color: foreground),
          SizedBox(width: height * 0.1),
          // ponytail: the title shrinks rather than truncates where the
          // width runs out — the out-of-credits card at an accessibility
          // text size is the case. That trades Apple's 43% proportion, which
          // it keeps everywhere it fits, against a clipped "Sign in with
          // Ap…", which is not one of the three titles they permit. Giving
          // the card's button the full row would buy back most of the width
          // if this ever needs to be exact.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                l10n.settingsAccountSignIn,
                maxLines: 1,
                softWrap: false,
                // The size already carries the text scale, and scaling it
                // twice would put the title out of proportion with the box.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: fontSize,
                  // Apple allows the weight to be tuned; this sits closest
                  // to the system button.
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
