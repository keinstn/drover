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
  String get agentAttachImage => 'Attach image';

  @override
  String get agentStopDictation => 'Stop dictation';

  @override
  String get agentDictateMessage => 'Dictate message';

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
}
