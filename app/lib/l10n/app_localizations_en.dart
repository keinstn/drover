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
  String get hostSetupNameLabel => 'Name (optional)';

  @override
  String get hostSetupHostLabel => 'Host';

  @override
  String get hostSetupHostRequired => 'Host is required';

  @override
  String get hostSetupPortLabel => 'Port';

  @override
  String get hostSetupPortInvalid =>
      'Port must be a number between 1 and 65535';

  @override
  String get hostSetupUserLabel => 'User';

  @override
  String get hostSetupUserRequired => 'User is required';

  @override
  String get hostSetupPrivateKeyLabel => 'Private key PEM';

  @override
  String get hostSetupPrivateKeyRequired => 'Private key is required';

  @override
  String get hostSetupPrivateKeyInvalid =>
      'This doesn\'t look like a private key. Paste the full PEM block, including the BEGIN and END lines.';

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
  String get hostSetupDemoIntro =>
      'New to drover? Try a scripted demo session first — no host required.';

  @override
  String get hostSetupDemoButton => 'Try the demo';

  @override
  String get demoHostDisplayName => 'Demo';

  @override
  String get demoBannerExit => 'Exit demo';

  @override
  String get demoBannerSetupConnection => 'Set up a connection';

  @override
  String get demoBannerDoneCopy =>
      'This is a demo. Connect your own host and this becomes real.';

  @override
  String get hostListTitle => 'Hosts';

  @override
  String get hostDeleteDialogTitle => 'Delete host?';

  @override
  String hostDeleteDialogBody(String name) {
    return 'The saved connection details for $name (including the SSH key) will be deleted.';
  }

  @override
  String get hostSwitcherTitle => 'Switch host';

  @override
  String get hostSwitcherManage => 'Manage hosts';

  @override
  String get hostAllHosts => 'All hosts';

  @override
  String get hostPickLaunchTarget => 'Launch on…';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonDelete => 'Delete';

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

  @override
  String get notificationRegistrationFailed =>
      'Couldn\'t enable notifications. Try opening Drover again.';

  @override
  String get notificationTargetUnavailable =>
      'The agent from this notification is no longer available.';

  @override
  String get hostPairNotifications => 'Create notification pairing code';

  @override
  String get hostPairingCodeTitle => 'Pair the notification plugin';

  @override
  String get hostPairingCodeIntro =>
      'Drover couldn\'t find the notification plugin on this host. Run this on the Herdr host to install it, then tap Create notification pairing code again — Drover will find it and pair for you.';

  @override
  String get hostPairingInstallCommandLabel => 'Install the plugin';

  @override
  String get hostPairingManualNote =>
      'Pairing by hand instead? The plugin\'s own setup script asks for the code and the URL below.';

  @override
  String get hostPairingCodeLabel => 'Pairing code';

  @override
  String get hostPairingUrlLabel => 'Completion URL';

  @override
  String get hostPairAutoDetectedTitle => 'Notification plugin detected';

  @override
  String get hostPairAutoDetectedBody =>
      'Drover found the drover.notify plugin already linked on this host. Set up push notification pairing automatically?';

  @override
  String get hostPairAutoDetectedConfirm => 'Set up';

  @override
  String get hostPairAutoPairedTitle => 'Notifications paired';

  @override
  String get hostPairAutoPairedBody =>
      'This host is now paired for blocked-agent push notifications.';

  @override
  String get commonClose => 'Close';

  @override
  String get commonCopy => 'Copy';

  @override
  String get errorHostKeyMismatch =>
      'The host\'s SSH key doesn\'t match the one trusted on first connection. If you didn\'t rebuild or replace the server, the connection may be intercepted — don\'t continue.';

  @override
  String get errorSshAuth =>
      'Couldn\'t sign in to the host. Check the username, private key, and passphrase.';

  @override
  String get errorHostConnection =>
      'Couldn\'t reach the host. Check that it\'s online and the address and port are correct.';

  @override
  String get errorHostConnectionLost =>
      'Lost the connection to the host. If you connect over a VPN, check that it\'s still active.';

  @override
  String get errorHerdrServerUnreachable =>
      'Connected to the host, but herdr isn\'t running on it. Start herdr on the host, then try again.';

  @override
  String herdrVersionTooOld(String found, String minimum) {
    return 'herdr $found on this host is older than the minimum supported version $minimum. Update herdr on the host to start agents.';
  }

  @override
  String get errorGeneric => 'Something went wrong.';

  @override
  String get errorDetailsLabel => 'Details';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonStop => 'Stop';

  @override
  String get commonLaunchAgent => 'Launch agent';

  @override
  String get agentStatusIdle => 'resting';

  @override
  String get agentStatusWorking => 'working';

  @override
  String get agentStatusBlocked => 'waiting for you';

  @override
  String get agentStatusDone => 'all done';

  @override
  String get agentStatusUnknown => 'unknown';

  @override
  String get agentModeNormal => 'Normal';

  @override
  String get agentModeAcceptEdit => 'Accept Edits';

  @override
  String get agentModePlan => 'Plan';

  @override
  String get agentModeAuto => 'Auto';

  @override
  String get agentModeBypass => 'Bypass';

  @override
  String get agentComposerHint => 'Send a message…';

  @override
  String get agentCycleModeTooltip => 'Cycle agent mode (shift+tab)';

  @override
  String get agentRemoveImage => 'Remove image';

  @override
  String get agentAttachImage => 'Add attachment';

  @override
  String get agentAttachFromLibrary => 'Photo';

  @override
  String get agentAttachFromCamera => 'Camera';

  @override
  String get agentStopAgent => 'Stop agent';

  @override
  String get agentStopDictation => 'Stop dictation';

  @override
  String get agentDictateMessage => 'Dictate message';

  @override
  String get agentSendEscape => 'Send Esc key';

  @override
  String get agentSendEnter => 'Send Enter key';

  @override
  String get agentShowArrowKeys => 'Show keys';

  @override
  String get agentHideArrowKeys => 'Hide keys';

  @override
  String get agentSendArrowLeft => 'Send Left arrow key';

  @override
  String get agentSendArrowUp => 'Send Up arrow key';

  @override
  String get agentSendArrowDown => 'Send Down arrow key';

  @override
  String get agentSendArrowRight => 'Send Right arrow key';

  @override
  String get agentNativeHistory => 'Conversation history';

  @override
  String get agentLiveTerminal => 'Live terminal';

  @override
  String get agentThinking => 'Thinking…';

  @override
  String get agentHistoryBeginning =>
      'Beginning of retained terminal history reached';

  @override
  String get agentAskUserSend => 'Send';

  @override
  String get agentAskUserClose => 'Close';

  @override
  String get agentAskUserCustomHint => 'Type something…';

  @override
  String agentAskUserQuestionNumber(int current, int total) {
    return 'Question $current of $total';
  }

  @override
  String get agentAskUserDismissed => 'The question is no longer available';

  @override
  String agentAskUserSubmitError(String error) {
    return 'Couldn\'t submit answer: $error';
  }

  @override
  String herdAgentBlocked(String name) {
    return '$name is blocked';
  }

  @override
  String get herdStopDialogTitle => 'Stop agent?';

  @override
  String herdStopDialogBody(String name, String paneId) {
    return '$name ($paneId) will be stopped. Any current work will be interrupted.';
  }

  @override
  String get herdNoAgents => 'No agents found';

  @override
  String get herdRenameWorkspaceTitle => 'Rename workspace';

  @override
  String get herdRenameWorkspaceField => 'Workspace name';

  @override
  String get herdRenameAgentTitle => 'Rename agent';

  @override
  String get herdRenameAgentField => 'Agent name';

  @override
  String get herdGreetingIntro => 'Welcome back. ';

  @override
  String herdGreetingWaitingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count agents',
      one: '1 agent',
    );
    return '$_temp0';
  }

  @override
  String get herdGreetingWaitingSuffix => ' waiting for your reply.';

  @override
  String get herdGreetingAllClear => 'Everyone\'s on track.';

  @override
  String get herdElapsedNow => 'now';

  @override
  String herdElapsedMinutes(int minutes) {
    return '${minutes}m ago';
  }

  @override
  String herdElapsedHours(int hours) {
    return '${hours}h ago';
  }

  @override
  String get herdSnippetThinking => 'Thinking things over…';

  @override
  String get agentSwitcherHerdTab => 'All';

  @override
  String get launchButton => 'Launch';

  @override
  String get launchNoAgents => 'No launchable agents found on the host';

  @override
  String get launchWorkingDir => 'Working directory';

  @override
  String get launchWorkingDirRequired => 'Working directory is required';

  @override
  String get launchAgentName => 'Agent name';

  @override
  String get launchNewWorkspace => 'New workspace';

  @override
  String get launchExistingWorkspace => 'Existing workspace';

  @override
  String get launchWorkspaceName => 'Workspace name';

  @override
  String get launchWorkspaceNameRequired => 'Workspace name is required';

  @override
  String get launchUseNewWorkspace => 'Use new workspace instead';

  @override
  String get launchNoExistingWorkspaces => 'No existing workspaces';

  @override
  String get launchSelectWorkspace => 'Select workspace';

  @override
  String launchUnnamedWorkspace(String id) {
    return 'Unnamed workspace ($id)';
  }

  @override
  String get launchBrowseDir => 'Browse';

  @override
  String get dirPickerTitle => 'Select directory';

  @override
  String get dirPickerUse => 'Use this directory';

  @override
  String get dirPickerParent => 'Parent directory';

  @override
  String get dirPickerShowHidden => 'Show hidden folders';

  @override
  String get dirPickerEmpty => 'No subfolders';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageSystem => 'System';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsNotifyBlocked => 'Blocked agents';

  @override
  String get settingsNotifyDone => 'Finished agents';

  @override
  String get settingsNotifyPluginUpdateTitle =>
      'Update the notification plugin';

  @override
  String settingsNotifyPluginUpdateSubtitle(String host, String version) {
    return '$host is running $version';
  }

  @override
  String settingsNotifyPluginUpdateIntro(String host, String version) {
    return '$host is running drover-notify $version. Reinstall it on the Herdr host to get the latest notifications.';
  }

  @override
  String get settingsNotifyPluginUninstallLabel => '1. Remove the old plugin';

  @override
  String get settingsNotifyPluginInstallLabel => '2. Install the latest';

  @override
  String get settingsDemo => 'Try the demo';

  @override
  String get settingsDemoSubtitle => 'A scripted session — no host required';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsVersionCopied => 'Version copied';

  @override
  String get settingsAssistant => 'Assistant';

  @override
  String get settingsVoiceAssistant => 'Voice assistant';

  @override
  String get settingsVoiceAssistantSubtitle =>
      'Talk to drover about your agents. Agent status and short summaries of their replies are sent to Google\'s Gemini Live API for the conversation.';

  @override
  String get settingsVoiceCredits => 'Voice credits';

  @override
  String get settingsVoiceCreditsSubtitle =>
      'One credit is one call, up to five minutes.';

  @override
  String get settingsVoiceCreditsCampaign =>
      'Voice is free for now: sign in with Apple and a few free credits are added, once.';

  @override
  String get settingsVoiceCreditsActivity => 'Recent credit activity';

  @override
  String get settingsVoiceCreditsNone => 'Nothing yet.';

  @override
  String get settingsVoiceCreditsFailed => 'Couldn\'t load your balance.';

  @override
  String get voiceLedgerCall => 'Voice call';

  @override
  String get voiceLedgerRefund => 'Returned';

  @override
  String get voiceLedgerGrant => 'Free credits';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsAccountSignIn => 'Sign in with Apple';

  @override
  String get settingsAccountSignedIn => 'Signed in with Apple';

  @override
  String get settingsAccountSignInFailed =>
      'Couldn\'t sign in. Tap to try again.';

  @override
  String get settingsAccountDelete => 'Delete account';

  @override
  String get accountDeleteTitle => 'Delete your account?';

  @override
  String get accountDeleteBody =>
      'Your sign-in, host pairings and any voice credits are deleted for good. Credits cannot be refunded or moved to another account. The hosts stay set up on this device, and would each need pairing again for notifications.';

  @override
  String get accountDeleteConfirm => 'Delete';

  @override
  String get accountDeleteFailed =>
      'Could not delete the account. Tap to try again.';

  @override
  String accountDeleteBalance(int credits) {
    String _temp0 = intl.Intl.pluralLogic(
      credits,
      locale: localeName,
      other: '$credits credits go',
      one: 'One credit goes',
    );
    return '$_temp0 with it.';
  }

  @override
  String get accountDeletedTitle => 'Account deleted';

  @override
  String get accountDeletedNotifyBody =>
      'Notification pairing was removed with it. Re-pair each host to keep getting notifications.';

  @override
  String get accountDeletedManageHosts => 'Manage hosts';

  @override
  String get herdVoiceButton => 'Voice assistant';

  @override
  String get herdVoiceButtonLive => 'Voice call in progress';

  @override
  String get voiceStatusConnecting => 'Connecting…';

  @override
  String get voiceStatusReady => 'Ready';

  @override
  String get voiceStatusLive => 'Listening';

  @override
  String get voiceStatusSpeaking => 'Speaking';

  @override
  String get voiceStatusEnded => 'Ended';

  @override
  String voiceStatusError(String error) {
    return 'Error: $error';
  }

  @override
  String get voiceMicPermissionDenied =>
      'Microphone access is off. Allow it in Settings to talk to drover.';

  @override
  String get voiceNoCreditsTitle => 'No credits left';

  @override
  String get voiceNoCreditsBody =>
      'A call costs one credit and there are none. The free credits are granted once, to a signed-in account. Nothing was recorded — the microphone never opened and no audio left the phone.';

  @override
  String get voiceCampaignOverTitle => 'The free credits have run out';

  @override
  String get voiceCampaignOverBody =>
      'Voice is free while the credits last, and they have run out for everyone — this is not your balance, and there is nothing on your side to put right. Nothing was recorded: the microphone never opened.';

  @override
  String voiceCredits(int credits) {
    String _temp0 = intl.Intl.pluralLogic(
      credits,
      locale: localeName,
      other: '$credits credits',
      one: '1 credit',
    );
    return '$_temp0';
  }

  @override
  String get voiceReceiptLength => 'Length';

  @override
  String voiceReceiptLengthValue(int minutes, int seconds) {
    return '$minutes min $seconds s';
  }

  @override
  String get voiceReceiptCost => 'Cost';

  @override
  String get voiceReceiptBalance => 'Balance';

  @override
  String get voiceReceiptFootnote =>
      'One credit, one call — however many times it reconnected along the way.';

  @override
  String get voiceSignInTitle => 'Sign in for your free credits';

  @override
  String get voiceSignInBody =>
      'The voice assistant is free for now, and the free credits go to a signed-in account. Signing in with Apple adds them — once — and it is also what keeps them if you reinstall drover. drover asks Apple for nothing but a stable identifier: no name, no email address.';

  @override
  String voiceToolCalled(String name) {
    return 'Called $name';
  }

  @override
  String get voiceInterrupted => 'Interrupted';

  @override
  String get voiceGoingAway => 'Reconnecting shortly';

  @override
  String get voiceResumed => 'Reconnected, continuing';

  @override
  String get voiceEnded => 'Session ended';

  @override
  String get voiceEnd => 'End';

  @override
  String get voiceRestart => 'Restart';

  @override
  String get voiceStart => 'Start';

  @override
  String get voiceGreeting => 'What should we start on?';

  @override
  String get voiceClose => 'Close';

  @override
  String get voiceHint =>
      '“Which agent is waiting for me?”\n“Tell claude to add tests too”\n“The invoice PDFs come out broken — what should I ask for?”';

  @override
  String get voiceHintHandoff =>
      'Work it out as you talk. Once it\'s settled, the call starts a new agent to take it on.';

  @override
  String voiceEventFinished(String name) {
    return '$name finished';
  }

  @override
  String voiceEventBlocked(String name) {
    return '$name is waiting for you';
  }

  @override
  String get voiceEventAnnounceFailed => 'Couldn\'t read the agent\'s state';

  @override
  String voiceDraftPending(String agent) {
    return 'Waiting to send to $agent';
  }

  @override
  String voiceDraftSent(String agent) {
    return 'Sent to $agent';
  }

  @override
  String get voiceDraftSend => 'Send';

  @override
  String get voiceUnsentDrafts =>
      'A draft is still pending — the button on its card still works';

  @override
  String get voiceSendFailed => 'Couldn\'t send the message';

  @override
  String voiceLaunchPending(String kind, String project) {
    return 'Waiting to start $kind in $project';
  }

  @override
  String voiceLaunchHeader(String kind, String project) {
    return '$kind in $project';
  }

  @override
  String voiceLaunchStarted(String kind, String project) {
    return 'Started $kind in $project';
  }

  @override
  String get voiceLaunchStart => 'Launch';

  @override
  String get voiceLaunchFailed => 'Couldn\'t start the agent';

  @override
  String get voiceCapReached => 'Session time limit reached';

  @override
  String get voiceBackgrounded => 'App went to the background';

  @override
  String get voiceConsentTitle => 'Voice uses Google Gemini';

  @override
  String get voiceConsentBody =>
      'The voice assistant runs on Google\'s Gemini Live. While a session is open, your microphone audio and transcripts of both sides of the conversation are sent to Google, along with the context it needs to answer you: your agents\' status, session titles and kinds, project folder names, any question an agent is waiting on with its options, and an agent\'s last reply as prose — which is also sent on its own when an agent finishes, even if you have said nothing. Code is stripped from that reply, fenced or inline, and a failed action reports a short code instead of the terminal\'s output. Prose is sent as written, so a path an agent typed in a sentence, or in the wording of a question, goes with it. Nothing is sent while no session is open. A call keeps listening while you use the rest of drover; leaving the app closes the microphone and stops sending, and returning to the conversation re-opens the microphone by itself and carries on where you left off. A session ends on its own after a time limit, and time spent away counts against it. Only End finishes a call for good, and you can tap it whenever you like.';

  @override
  String get voiceConsentAccept => 'Allow and continue';

  @override
  String get voiceConsentDecline => 'Not now';
}
