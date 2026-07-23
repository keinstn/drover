import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/infra/ssh_command_runner.dart';
import 'package:drover/src/widgets/error_message_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Object error) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: ErrorMessageView(error)),
);

void main() {
  group('ErrorMessageView renders the classified localized headline', () {
    testWidgets('ssh auth failure', (tester) async {
      await tester.pumpWidget(_host(SshAuthException('raw auth text')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Check the username, private key, and passphrase'),
        findsOneWidget,
      );
    });

    testWidgets('host-key mismatch shows the warning and fingerprints on '
        'expanding details', (tester) async {
      await tester.pumpWidget(
        _host(
          HerdrException(
            'transport',
            'wrapped',
            cause: SshHostKeyMismatchException(
              expected: 'SHA256:expected-fp',
              observed: 'SHA256:observed-fp',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Localized headline, not the raw wrapper text.
      expect(
        find.textContaining('the connection may be intercepted'),
        findsOneWidget,
      );
      expect(find.text('wrapped'), findsNothing);

      // Details expander reveals the raw fingerprints.
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SHA256:expected-fp'), findsOneWidget);
      expect(find.textContaining('SHA256:observed-fp'), findsOneWidget);
    });

    testWidgets('unknown herdr failure passes through the cleaned detail', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const HerdrException('transport', 'missing agents field')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('missing agents field'), findsOneWidget);
      // No wrapper-type noise leaks into the UI.
      expect(find.textContaining('HerdrException'), findsNothing);
    });
  });
}
