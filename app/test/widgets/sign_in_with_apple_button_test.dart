import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/widgets/sign_in_with_apple_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Apple's own floors, quoted from the Human Interface Guidelines. Asserted
/// as floors rather than as pixel values: the button is allowed to be bigger
/// than these, and a test that pins the exact size would fail on a text size
/// that legitimately grows it.
const _minWidth = 140.0;
const _minHeight = 30.0;
const _titleRatio = 0.43;

/// Apple's own artwork, spelled out here rather than imported so that renaming
/// the asset out from under the button fails a test rather than a device.
const _markBlack = AssetImage('assets/sign_in_with_apple/mark_black.png');
const _markWhite = AssetImage('assets/sign_in_with_apple/mark_white.png');

Widget _app({
  Locale locale = const Locale('en'),
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: theme ?? droverLightTheme,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      // Centre, not stretch: this is the button left to its own width, which
      // is where Apple's minimum width has to hold.
      child: const Center(child: SignInWithAppleButton(onPressed: _noop)),
    ),
  ),
);

/// The button in a box of a given width — the card and the sheet both hand
/// it a width rather than letting it take the screen's.
Widget _boxed({required double width, required TextScaler textScaler}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverLightTheme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Center(
            child: SizedBox(
              width: width,
              child: const SignInWithAppleButton(onPressed: _noop),
            ),
          ),
        ),
      ),
    );

void _noop() {}

Size _buttonSize(WidgetTester tester) =>
    tester.getSize(find.byType(SignInWithAppleButton));

Text _title(WidgetTester tester) => tester.widget<Text>(
  find
      .descendant(
        of: find.byType(SignInWithAppleButton),
        matching: find.byType(Text),
      )
      .first,
);

void main() {
  testWidgets('renders Apple\'s English title', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.text('Sign in with Apple'), findsOneWidget);
    // Apple's artwork, not a redrawn glyph.
    expect(find.image(_markWhite), findsOneWidget);
  });

  testWidgets('renders Apple\'s Japanese title', (tester) async {
    await tester.pumpWidget(_app(locale: const Locale('ja')));

    // Apple writes it without a space — support.apple.com/ja-jp/102609.
    expect(find.text('Appleでサインイン'), findsOneWidget);
    expect(find.text('Apple でサインイン'), findsNothing);
  });

  testWidgets('clears Apple\'s minimum size and title proportion', (
    tester,
  ) async {
    await tester.pumpWidget(_app());

    final size = _buttonSize(tester);
    expect(size.width, greaterThanOrEqualTo(_minWidth));
    expect(size.height, greaterThanOrEqualTo(_minHeight));
    // "the button's height would be 233% of the title's font size" — the
    // title may not be bigger than the box allows for.
    expect(
      size.height,
      greaterThanOrEqualTo(_title(tester).style!.fontSize! / _titleRatio - 0.5),
    );
  });

  testWidgets('keeps the proportion at an accessibility text size', (
    tester,
  ) async {
    await tester.pumpWidget(_app(textScaler: const TextScaler.linear(2)));
    // A RenderFlex overflow would fail the test on its own; this is the
    // button growing with the title instead of clipping it.
    final size = _buttonSize(tester);

    expect(size.height, greaterThan(SignInWithAppleButton.baseHeight));
    expect(
      size.height,
      greaterThanOrEqualTo(_title(tester).style!.fontSize! / _titleRatio - 0.5),
    );
    expect(find.text('Sign in with Apple'), findsOneWidget);
  });

  testWidgets('keeps the whole title in the narrowest place it appears', (
    tester,
  ) async {
    // The out-of-credits card is the tightest of the three: ~0.85 of a
    // phone's width, less its own padding. A clipped "Sign in with Ap…" is
    // not one of the three titles Apple permits, so this is a compliance
    // check, not a cosmetic one.
    await tester.pumpWidget(
      _boxed(width: 316, textScaler: const TextScaler.linear(2)),
    );

    expect(
      tester
          .renderObject<RenderParagraph>(find.text('Sign in with Apple'))
          .didExceedMaxLines,
      isFalse,
    );
  });

  testWidgets('is black-on-light in the light theme', (tester) async {
    await tester.pumpWidget(_app(theme: droverLightTheme));

    expect(_fill(tester), Colors.black);
    expect(_title(tester).style!.color, Colors.white);
  });

  testWidgets('is white-on-dark in the dark theme', (tester) async {
    await tester.pumpWidget(_app(theme: droverDarkTheme));

    expect(_fill(tester), Colors.white);
    expect(_title(tester).style!.color, Colors.black);
  });

  testWidgets('takes the mark Apple names for the ink, not the fill', (
    tester,
  ) async {
    // Apple's files are opaque, not transparent glyphs: the black mark comes
    // on a white square, the white mark on a black one. Light fills the
    // button black, so light takes the white mark — the pairing reads
    // backwards, and an edit that "corrects" it paints a black apple on a
    // black button. Each theme asserts the other mark absent, because only
    // that half fails when the two are swapped.
    await tester.pumpWidget(_app(theme: droverLightTheme));

    expect(find.image(_markWhite), findsOneWidget);
    expect(find.image(_markBlack), findsNothing);

    await tester.pumpWidget(_app(theme: droverDarkTheme));
    // MaterialApp crossfades between themes, and the halfway theme is still
    // the light one.
    await tester.pumpAndSettle();

    expect(find.image(_markBlack), findsOneWidget);
    expect(find.image(_markWhite), findsNothing);
  });

  testWidgets('sizes the mark to the whole button height', (tester) async {
    // Apple's rule for their file, and it is about the padding built into it:
    // the mark is 19 of the 44pt square, so a mark that fills the height
    // paints at 43% of it.
    await tester.pumpWidget(_app());

    expect(
      tester.getSize(find.image(_markWhite)).height,
      _buttonSize(tester).height,
    );
  });

  testWidgets('a disabled button still paints Apple\'s two colours', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: droverLightTheme,
        home: const Center(child: SignInWithAppleButton(onPressed: null)),
      ),
    );

    // Material would grey a disabled fill; Apple permits black or white and
    // nothing in between, so the busy moment keeps the same two colours.
    expect(_fill(tester), Colors.black);
    expect(_title(tester).style!.color, Colors.white);
  });
}

/// What the button actually paints behind its title.
Color? _fill(WidgetTester tester) => tester
    .widget<Material>(
      find
          .descendant(
            of: find.byType(SignInWithAppleButton),
            matching: find.byType(Material),
          )
          .first,
    )
    .color;
