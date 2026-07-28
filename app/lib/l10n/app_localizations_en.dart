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
      'On the Herdr host, copy and run these commands. Replace /path/to/drover with the checkout path. When setup asks, paste the pairing code.';

  @override
  String get hostPairingLinkCommandLabel =>
      '1. Link the plugin (first time only)';

  @override
  String get hostPairingSetupCommandLabel => '2. Run setup';

  @override
  String get hostPairingCodeLabel => '3. Pairing code';

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
  String get settingsDemo => 'Try the demo';

  @override
  String get settingsDemoSubtitle => 'A scripted session — no host required';
}
