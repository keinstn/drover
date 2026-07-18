import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
  ];

  /// No description provided for @hostSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Host setup'**
  String get hostSetupTitle;

  /// No description provided for @hostSetupHostLabel.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get hostSetupHostLabel;

  /// No description provided for @hostSetupHostRequired.
  ///
  /// In en, this message translates to:
  /// **'Host is required'**
  String get hostSetupHostRequired;

  /// No description provided for @hostSetupPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get hostSetupPortLabel;

  /// No description provided for @hostSetupUserLabel.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get hostSetupUserLabel;

  /// No description provided for @hostSetupUserRequired.
  ///
  /// In en, this message translates to:
  /// **'User is required'**
  String get hostSetupUserRequired;

  /// No description provided for @hostSetupPrivateKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Private key PEM'**
  String get hostSetupPrivateKeyLabel;

  /// No description provided for @hostSetupPrivateKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Private key is required'**
  String get hostSetupPrivateKeyRequired;

  /// No description provided for @hostSetupPassphraseLabel.
  ///
  /// In en, this message translates to:
  /// **'Passphrase'**
  String get hostSetupPassphraseLabel;

  /// No description provided for @hostSetupAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get hostSetupAdvanced;

  /// No description provided for @hostSetupHerdrBinLabel.
  ///
  /// In en, this message translates to:
  /// **'Herdr binary path'**
  String get hostSetupHerdrBinLabel;

  /// No description provided for @hostSetupTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get hostSetupTestConnection;

  /// No description provided for @hostSetupSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get hostSetupSave;

  /// No description provided for @hostSetupResetButton.
  ///
  /// In en, this message translates to:
  /// **'Reset host'**
  String get hostSetupResetButton;

  /// No description provided for @hostResetDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset host?'**
  String get hostResetDialogTitle;

  /// No description provided for @hostResetDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This deletes the saved connection details (including the SSH key) and returns to the setup screen.'**
  String get hostResetDialogBody;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get commonReset;

  /// No description provided for @testConnectionOk.
  ///
  /// In en, this message translates to:
  /// **'OK — {count, plural, =1{1 agent} other{{count} agents}}'**
  String testConnectionOk(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
