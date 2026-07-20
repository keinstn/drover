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

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonStop => 'Stop';

  @override
  String get commonLaunchAgent => 'Launch agent';

  @override
  String get agentStatusIdle => 'idle';

  @override
  String get agentStatusWorking => 'working';

  @override
  String get agentStatusBlocked => 'blocked';

  @override
  String get agentStatusDone => 'done';

  @override
  String get agentStatusUnknown => 'unknown';

  @override
  String get agentComposerHint => 'Message agent…';

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
  String get agentNativeHistory => 'Conversation history';

  @override
  String get agentLiveTerminal => 'Live terminal';

  @override
  String get agentThinking => 'Thinking…';

  @override
  String get agentHistoryBeginning =>
      'Beginning of retained terminal history reached';

  @override
  String agentNativeHistoryError(String error) {
    return 'Native history unavailable: $error';
  }

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
  String get launchButton => 'Launch';

  @override
  String get launchNoAgents => 'No launchable agents found on the host';

  @override
  String get launchWorkingDir => 'Working directory';

  @override
  String get launchAgentName => 'Agent name';

  @override
  String get launchNewWorkspace => 'New workspace';

  @override
  String get launchExistingWorkspace => 'Existing workspace';

  @override
  String get launchWorkspaceName => 'Workspace name';

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
}
