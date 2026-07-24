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

  /// No description provided for @hostSetupNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get hostSetupNameLabel;

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

  /// No description provided for @hostSetupPortInvalid.
  ///
  /// In en, this message translates to:
  /// **'Port must be a number between 1 and 65535'**
  String get hostSetupPortInvalid;

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

  /// No description provided for @hostSetupPrivateKeyInvalid.
  ///
  /// In en, this message translates to:
  /// **'This doesn\'t look like a private key. Paste the full PEM block, including the BEGIN and END lines.'**
  String get hostSetupPrivateKeyInvalid;

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

  /// No description provided for @hostListTitle.
  ///
  /// In en, this message translates to:
  /// **'Hosts'**
  String get hostListTitle;

  /// No description provided for @hostDeleteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete host?'**
  String get hostDeleteDialogTitle;

  /// No description provided for @hostDeleteDialogBody.
  ///
  /// In en, this message translates to:
  /// **'The saved connection details for {name} (including the SSH key) will be deleted.'**
  String hostDeleteDialogBody(String name);

  /// No description provided for @hostSwitcherTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch host'**
  String get hostSwitcherTitle;

  /// No description provided for @hostSwitcherManage.
  ///
  /// In en, this message translates to:
  /// **'Manage hosts'**
  String get hostSwitcherManage;

  /// No description provided for @hostAllHosts.
  ///
  /// In en, this message translates to:
  /// **'All hosts'**
  String get hostAllHosts;

  /// No description provided for @hostPickLaunchTarget.
  ///
  /// In en, this message translates to:
  /// **'Launch on…'**
  String get hostPickLaunchTarget;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @testConnectionOk.
  ///
  /// In en, this message translates to:
  /// **'OK — {count, plural, =1{1 agent} other{{count} agents}}'**
  String testConnectionOk(int count);

  /// No description provided for @notificationRegistrationFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t enable notifications. Try opening Drover again.'**
  String get notificationRegistrationFailed;

  /// No description provided for @notificationTargetUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The agent from this notification is no longer available.'**
  String get notificationTargetUnavailable;

  /// No description provided for @hostPairNotifications.
  ///
  /// In en, this message translates to:
  /// **'Create notification pairing code'**
  String get hostPairNotifications;

  /// No description provided for @hostPairingCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair the notification plugin'**
  String get hostPairingCodeTitle;

  /// No description provided for @hostPairingCodeIntro.
  ///
  /// In en, this message translates to:
  /// **'On the Herdr host, copy and run these commands. Replace /path/to/drover with the checkout path. When setup asks, paste the pairing code.'**
  String get hostPairingCodeIntro;

  /// No description provided for @hostPairingLinkCommandLabel.
  ///
  /// In en, this message translates to:
  /// **'1. Link the plugin (first time only)'**
  String get hostPairingLinkCommandLabel;

  /// No description provided for @hostPairingSetupCommandLabel.
  ///
  /// In en, this message translates to:
  /// **'2. Run setup'**
  String get hostPairingSetupCommandLabel;

  /// No description provided for @hostPairingCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'3. Pairing code'**
  String get hostPairingCodeLabel;

  /// No description provided for @hostPairingUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Completion URL'**
  String get hostPairingUrlLabel;

  /// No description provided for @hostPairAutoDetectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Notification plugin detected'**
  String get hostPairAutoDetectedTitle;

  /// No description provided for @hostPairAutoDetectedBody.
  ///
  /// In en, this message translates to:
  /// **'Drover found the drover.notify plugin already linked on this host. Set up push notification pairing automatically?'**
  String get hostPairAutoDetectedBody;

  /// No description provided for @hostPairAutoDetectedConfirm.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get hostPairAutoDetectedConfirm;

  /// No description provided for @hostPairAutoPairedTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications paired'**
  String get hostPairAutoPairedTitle;

  /// No description provided for @hostPairAutoPairedBody.
  ///
  /// In en, this message translates to:
  /// **'This host is now paired for blocked-agent push notifications.'**
  String get hostPairAutoPairedBody;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @commonCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// No description provided for @errorHostKeyMismatch.
  ///
  /// In en, this message translates to:
  /// **'The host\'s SSH key doesn\'t match the one trusted on first connection. If you didn\'t rebuild or replace the server, the connection may be intercepted — don\'t continue.'**
  String get errorHostKeyMismatch;

  /// No description provided for @errorSshAuth.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign in to the host. Check the username, private key, and passphrase.'**
  String get errorSshAuth;

  /// No description provided for @errorHostConnection.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the host. Check that it\'s online and the address and port are correct.'**
  String get errorHostConnection;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong.'**
  String get errorGeneric;

  /// No description provided for @errorDetailsLabel.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get errorDetailsLabel;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get commonStop;

  /// No description provided for @commonLaunchAgent.
  ///
  /// In en, this message translates to:
  /// **'Launch agent'**
  String get commonLaunchAgent;

  /// No description provided for @agentStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'resting'**
  String get agentStatusIdle;

  /// No description provided for @agentStatusWorking.
  ///
  /// In en, this message translates to:
  /// **'working'**
  String get agentStatusWorking;

  /// No description provided for @agentStatusBlocked.
  ///
  /// In en, this message translates to:
  /// **'waiting for you'**
  String get agentStatusBlocked;

  /// No description provided for @agentStatusDone.
  ///
  /// In en, this message translates to:
  /// **'all done'**
  String get agentStatusDone;

  /// No description provided for @agentStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get agentStatusUnknown;

  /// No description provided for @agentModeNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get agentModeNormal;

  /// No description provided for @agentModeAcceptEdit.
  ///
  /// In en, this message translates to:
  /// **'Accept Edits'**
  String get agentModeAcceptEdit;

  /// No description provided for @agentModePlan.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get agentModePlan;

  /// No description provided for @agentModeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get agentModeAuto;

  /// No description provided for @agentModeBypass.
  ///
  /// In en, this message translates to:
  /// **'Bypass'**
  String get agentModeBypass;

  /// No description provided for @agentComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Send a message…'**
  String get agentComposerHint;

  /// No description provided for @agentCycleModeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Cycle agent mode (shift+tab)'**
  String get agentCycleModeTooltip;

  /// No description provided for @agentRemoveImage.
  ///
  /// In en, this message translates to:
  /// **'Remove image'**
  String get agentRemoveImage;

  /// No description provided for @agentAttachImage.
  ///
  /// In en, this message translates to:
  /// **'Add attachment'**
  String get agentAttachImage;

  /// No description provided for @agentAttachFromLibrary.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get agentAttachFromLibrary;

  /// No description provided for @agentAttachFromCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get agentAttachFromCamera;

  /// No description provided for @agentStopAgent.
  ///
  /// In en, this message translates to:
  /// **'Stop agent'**
  String get agentStopAgent;

  /// No description provided for @agentStopDictation.
  ///
  /// In en, this message translates to:
  /// **'Stop dictation'**
  String get agentStopDictation;

  /// No description provided for @agentDictateMessage.
  ///
  /// In en, this message translates to:
  /// **'Dictate message'**
  String get agentDictateMessage;

  /// No description provided for @agentSendEscape.
  ///
  /// In en, this message translates to:
  /// **'Send Esc key'**
  String get agentSendEscape;

  /// No description provided for @agentSendEnter.
  ///
  /// In en, this message translates to:
  /// **'Send Enter key'**
  String get agentSendEnter;

  /// No description provided for @agentNativeHistory.
  ///
  /// In en, this message translates to:
  /// **'Conversation history'**
  String get agentNativeHistory;

  /// No description provided for @agentLiveTerminal.
  ///
  /// In en, this message translates to:
  /// **'Live terminal'**
  String get agentLiveTerminal;

  /// No description provided for @agentThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get agentThinking;

  /// No description provided for @agentHistoryBeginning.
  ///
  /// In en, this message translates to:
  /// **'Beginning of retained terminal history reached'**
  String get agentHistoryBeginning;

  /// No description provided for @agentAskUserSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get agentAskUserSend;

  /// No description provided for @agentAskUserClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get agentAskUserClose;

  /// No description provided for @agentAskUserCustomHint.
  ///
  /// In en, this message translates to:
  /// **'Type something…'**
  String get agentAskUserCustomHint;

  /// No description provided for @agentAskUserQuestionNumber.
  ///
  /// In en, this message translates to:
  /// **'Question {current} of {total}'**
  String agentAskUserQuestionNumber(int current, int total);

  /// No description provided for @agentAskUserDismissed.
  ///
  /// In en, this message translates to:
  /// **'The question is no longer available'**
  String get agentAskUserDismissed;

  /// No description provided for @agentAskUserSubmitError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t submit answer: {error}'**
  String agentAskUserSubmitError(String error);

  /// No description provided for @herdAgentBlocked.
  ///
  /// In en, this message translates to:
  /// **'{name} is blocked'**
  String herdAgentBlocked(String name);

  /// No description provided for @herdStopDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop agent?'**
  String get herdStopDialogTitle;

  /// No description provided for @herdStopDialogBody.
  ///
  /// In en, this message translates to:
  /// **'{name} ({paneId}) will be stopped. Any current work will be interrupted.'**
  String herdStopDialogBody(String name, String paneId);

  /// No description provided for @herdNoAgents.
  ///
  /// In en, this message translates to:
  /// **'No agents found'**
  String get herdNoAgents;

  /// No description provided for @herdRenameWorkspaceTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename workspace'**
  String get herdRenameWorkspaceTitle;

  /// No description provided for @herdRenameWorkspaceField.
  ///
  /// In en, this message translates to:
  /// **'Workspace name'**
  String get herdRenameWorkspaceField;

  /// No description provided for @herdRenameAgentTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename agent'**
  String get herdRenameAgentTitle;

  /// No description provided for @herdRenameAgentField.
  ///
  /// In en, this message translates to:
  /// **'Agent name'**
  String get herdRenameAgentField;

  /// No description provided for @herdGreetingIntro.
  ///
  /// In en, this message translates to:
  /// **'Welcome back. '**
  String get herdGreetingIntro;

  /// No description provided for @herdGreetingWaitingCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 agent} other{{count} agents}}'**
  String herdGreetingWaitingCount(int count);

  /// No description provided for @herdGreetingWaitingSuffix.
  ///
  /// In en, this message translates to:
  /// **' waiting for your reply.'**
  String get herdGreetingWaitingSuffix;

  /// No description provided for @herdGreetingAllClear.
  ///
  /// In en, this message translates to:
  /// **'Everyone\'s on track.'**
  String get herdGreetingAllClear;

  /// No description provided for @herdElapsedNow.
  ///
  /// In en, this message translates to:
  /// **'now'**
  String get herdElapsedNow;

  /// No description provided for @herdElapsedMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m ago'**
  String herdElapsedMinutes(int minutes);

  /// No description provided for @herdElapsedHours.
  ///
  /// In en, this message translates to:
  /// **'{hours}h ago'**
  String herdElapsedHours(int hours);

  /// No description provided for @herdSnippetThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking things over…'**
  String get herdSnippetThinking;

  /// No description provided for @agentSwitcherHerdTab.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get agentSwitcherHerdTab;

  /// No description provided for @launchButton.
  ///
  /// In en, this message translates to:
  /// **'Launch'**
  String get launchButton;

  /// No description provided for @launchNoAgents.
  ///
  /// In en, this message translates to:
  /// **'No launchable agents found on the host'**
  String get launchNoAgents;

  /// No description provided for @launchWorkingDir.
  ///
  /// In en, this message translates to:
  /// **'Working directory'**
  String get launchWorkingDir;

  /// No description provided for @launchWorkingDirRequired.
  ///
  /// In en, this message translates to:
  /// **'Working directory is required'**
  String get launchWorkingDirRequired;

  /// No description provided for @launchAgentName.
  ///
  /// In en, this message translates to:
  /// **'Agent name'**
  String get launchAgentName;

  /// No description provided for @launchNewWorkspace.
  ///
  /// In en, this message translates to:
  /// **'New workspace'**
  String get launchNewWorkspace;

  /// No description provided for @launchExistingWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Existing workspace'**
  String get launchExistingWorkspace;

  /// No description provided for @launchWorkspaceName.
  ///
  /// In en, this message translates to:
  /// **'Workspace name'**
  String get launchWorkspaceName;

  /// No description provided for @launchWorkspaceNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Workspace name is required'**
  String get launchWorkspaceNameRequired;

  /// No description provided for @launchUseNewWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Use new workspace instead'**
  String get launchUseNewWorkspace;

  /// No description provided for @launchNoExistingWorkspaces.
  ///
  /// In en, this message translates to:
  /// **'No existing workspaces'**
  String get launchNoExistingWorkspaces;

  /// No description provided for @launchSelectWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Select workspace'**
  String get launchSelectWorkspace;

  /// No description provided for @launchUnnamedWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Unnamed workspace ({id})'**
  String launchUnnamedWorkspace(String id);

  /// No description provided for @launchBrowseDir.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get launchBrowseDir;

  /// No description provided for @dirPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Select directory'**
  String get dirPickerTitle;

  /// No description provided for @dirPickerUse.
  ///
  /// In en, this message translates to:
  /// **'Use this directory'**
  String get dirPickerUse;

  /// No description provided for @dirPickerParent.
  ///
  /// In en, this message translates to:
  /// **'Parent directory'**
  String get dirPickerParent;

  /// No description provided for @dirPickerShowHidden.
  ///
  /// In en, this message translates to:
  /// **'Show hidden folders'**
  String get dirPickerShowHidden;

  /// No description provided for @dirPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No subfolders'**
  String get dirPickerEmpty;
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
