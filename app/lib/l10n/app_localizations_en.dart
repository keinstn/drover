// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get hostSetupTitle => 'Host setup';

  @override
  String get hostSetupHostLabel => 'Host';

  @override
  String get hostSetupHostRequired => 'Host is required';

  @override
  String get hostSetupPortLabel => 'Port';

  @override
  String get hostSetupUserLabel => 'User';

  @override
  String get hostSetupUserRequired => 'User is required';

  @override
  String get hostSetupPrivateKeyLabel => 'Private key PEM';

  @override
  String get hostSetupPrivateKeyRequired => 'Private key is required';

  @override
  String get hostSetupPassphraseLabel => 'Passphrase';

  @override
  String get hostSetupAdvanced => 'Advanced';

  @override
  String get hostSetupHerdrBinLabel => 'Herdr binary path';

  @override
  String get hostSetupTestConnection => 'Test connection';

  @override
  String get hostSetupSave => 'Save';

  @override
  String get hostSetupResetButton => 'Reset host';

  @override
  String get hostResetDialogTitle => 'Reset host?';

  @override
  String get hostResetDialogBody =>
      'This deletes the saved connection details (including the SSH key) and returns to the setup screen.';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonReset => 'Reset';

  @override
  String testConnectionOk(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count agents',
      one: '1 agent',
    );
    return 'OK — $_temp0';
  }
}
