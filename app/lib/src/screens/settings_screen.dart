import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../firebase/voice_wallet.dart';
import '../infra/shell_command.dart';
import '../notifications/notify_plugin_version.dart';
import '../widgets/copyable_value.dart';
import '../widgets/top_toast.dart';

/// App-level settings: theme, language, push opt-ins, and a shortcut into
/// host management. Takes plain values rather than reading a settings store
/// directly — the caller owns persistence and rebuilds this screen (and the
/// rest of the app) when any of them changes.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.locale,
    required this.notifyOnBlocked,
    required this.notifyOnDone,
    required this.onThemeModeChanged,
    required this.onLocaleChanged,
    required this.onNotifyOnBlockedChanged,
    required this.onNotifyOnDoneChanged,
    required this.voiceAssistantEnabled,
    required this.onVoiceAssistantChanged,
    required this.appleSignedIn,
    required this.onSignInWithApple,
    required this.onDeleteAccount,
    required this.onManageHosts,
    required this.hasHosts,
    this.onEnterDemo,
    this.appVersion,
    this.staleNotifyPlugins,
    this.voiceWallet,
  });

  final ThemeMode themeMode;

  /// null = follow the device locale.
  final Locale? locale;

  /// Per-device push opt-ins, one per event kind the backend delivers.
  final bool notifyOnBlocked;
  final bool notifyOnDone;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<Locale?> onLocaleChanged;
  final ValueChanged<bool> onNotifyOnBlockedChanged;
  final ValueChanged<bool> onNotifyOnDoneChanged;
  final bool voiceAssistantEnabled;
  final ValueChanged<bool> onVoiceAssistantChanged;

  /// Whether an Apple ID is already attached to the Firebase account. A bool,
  /// not a user object: no identifier is requested from Apple, so there is
  /// none to render — and none this screen could leak.
  final bool appleSignedIn;

  /// Links the Apple ID, throwing if it could not be done. The row renders
  /// that failure itself; flipping [appleSignedIn] on success is the
  /// caller's job, same as every other value on this screen.
  final Future<void> Function() onSignInWithApple;

  /// Deletes the account, throwing if it could not be done. Called only
  /// after the confirmation dialog this screen shows, and the row renders a
  /// failure itself; resetting [appleSignedIn] on success is the caller's
  /// job, same as [onSignInWithApple].
  final Future<void> Function() onDeleteAccount;
  final VoidCallback onManageHosts;

  /// Whether any host is configured on this device — including in demo mode,
  /// where [staleNotifyPlugins] is null because the demo must not probe them
  /// over SSH. Gates the post-delete re-pair nudge, which cares only about
  /// there being a host to re-pair, not about its plugin's staleness.
  final bool hasHosts;

  /// Enters the scripted demo session. The first-run setup screen offers it
  /// too, but only there — this row is how someone who already configured a
  /// host (or dismissed the first-run offer) can still find the intro. Null
  /// hides the row, e.g. when settings was opened from inside the demo.
  final VoidCallback? onEnterDemo;

  /// `"<marketing version> (<build number>)"`, read from the bundle at
  /// startup by the caller. Null *or blank* hides the row — e.g. when the
  /// platform lookup failed; an empty value would be worse than none.
  final String? appVersion;

  /// One already-started probe future per host, rather than one combined
  /// future or a callback: a callback would re-probe every host over SSH on
  /// every rebuild (this screen is rebuilt by a `StatefulBuilder` on every
  /// theme/locale/switch change), and combining them with e.g. `Future.wait`
  /// would let the slowest host's probe hold back a row whose own probe
  /// already answered.
  final List<Future<StaleNotifyPlugin?>>? staleNotifyPlugins;

  /// An already-started balance fetch, for the same reason
  /// [staleNotifyPlugins] is one: this screen is rebuilt on every switch,
  /// and a future created here would call the wallet Function again each
  /// time. Null hides the balance entirely — previews and any build without
  /// Firebase behind it.
  final Future<VoiceWallet>? voiceWallet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    // Bound once so the checked value and the rendered value can't diverge.
    final version = appVersion?.trim();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          ListTile(
            key: const ValueKey('settings_hosts_tile'),
            leading: const Icon(Icons.dns),
            title: Text(l10n.hostListTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: onManageHosts,
          ),
          if (onEnterDemo != null)
            ListTile(
              key: const ValueKey('settings_demo_tile'),
              leading: const Icon(Icons.play_circle_outline),
              title: Text(l10n.settingsDemo),
              subtitle: Text(l10n.settingsDemoSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: onEnterDemo,
            ),
          _sectionHeader(context, l10n.settingsAppearance),
          ListTile(
            key: const ValueKey('settings_theme_tile'),
            leading: const Icon(Icons.brightness_6),
            title: Text(l10n.settingsTheme),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _themeModeLabel(l10n, themeMode),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _showThemeSheet(
              context,
              current: themeMode,
              onSelect: onThemeModeChanged,
            ),
          ),
          ListTile(
            key: const ValueKey('settings_language_tile'),
            leading: const Icon(Icons.language),
            title: Text(l10n.settingsLanguage),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _localeLabel(l10n, locale),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _showLanguageSheet(
              context,
              current: locale,
              onSelect: onLocaleChanged,
            ),
          ),
          _sectionHeader(context, l10n.settingsNotifications),
          SwitchListTile(
            key: const ValueKey('settings_notify_blocked_tile'),
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(l10n.settingsNotifyBlocked),
            value: notifyOnBlocked,
            onChanged: onNotifyOnBlockedChanged,
          ),
          SwitchListTile(
            key: const ValueKey('settings_notify_done_tile'),
            secondary: const Icon(Icons.task_alt),
            title: Text(l10n.settingsNotifyDone),
            value: notifyOnDone,
            onChanged: onNotifyOnDoneChanged,
          ),
          // One FutureBuilder per host so a row appears as soon as its own
          // probe resolves, instead of all rows waiting on the slowest host.
          for (final (index, probe)
              in (staleNotifyPlugins ?? const <Future<StaleNotifyPlugin?>>[])
                  .indexed)
            FutureBuilder<StaleNotifyPlugin?>(
              future: probe,
              builder: (context, snapshot) {
                // Fail-quiet: a probe that is still running, failed, or found
                // nothing renders nothing at all. A spinner or an error here
                // would be noise in a screen the user opened for something
                // else.
                final entry = snapshot.data;
                if (entry == null) return const SizedBox.shrink();
                return ListTile(
                  key: ValueKey('settings_notify_plugin_update_tile_$index'),
                  leading: const Icon(Icons.system_update),
                  title: Text(l10n.settingsNotifyPluginUpdateTitle),
                  subtitle: Text(
                    l10n.settingsNotifyPluginUpdateSubtitle(
                      entry.hostName,
                      entry.installedVersion,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPluginUpdateDialog(context, entry),
                );
              },
            ),
          _sectionHeader(context, l10n.settingsAssistant),
          SwitchListTile(
            key: const ValueKey('settings_voice_assistant_tile'),
            secondary: const Icon(Icons.mic),
            title: Text(l10n.settingsVoiceAssistant),
            subtitle: Text(l10n.settingsVoiceAssistantSubtitle),
            value: voiceAssistantEnabled,
            onChanged: onVoiceAssistantChanged,
          ),
          if (voiceWallet != null)
            FutureBuilder<VoiceWallet>(
              future: voiceWallet,
              builder: _voiceCredits,
            ),
          _sectionHeader(context, l10n.settingsAccount),
          _AccountTile(signedIn: appleSignedIn, onSignIn: onSignInWithApple),
          // Offered whether or not an Apple ID is attached: an anonymous
          // account is still an account, with a wallet hanging off its uid.
          // Reads the same already-started future the section above does, so
          // the confirmation can name what the balance actually is.
          FutureBuilder<VoiceWallet>(
            future: voiceWallet,
            builder: (context, snapshot) => _DeleteAccountTile(
              onDelete: onDeleteAccount,
              credits: snapshot.data?.credits ?? 0,
              onManageHosts: onManageHosts,
              hasHosts: hasHosts,
            ),
          ),
          if (version != null && version.isNotEmpty) ...[
            // Detaches the row from the section above, so a footer doesn't
            // read as one of its settings.
            const Divider(height: 32),
            ListTile(
              key: const ValueKey('settings_version_tile'),
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.settingsVersion),
              // No chevron: this row copies rather than navigates, and the
              // missing chevron is what says so.
              trailing: Text(
                version,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: version));
                showTopToast(context, l10n.settingsVersionCopied);
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// The account row: signed out it offers Sign in with Apple, signed in it
/// says so and does nothing else. No sign-out — once a balance hangs off the
/// account, signing out would strand it.
///
/// Stateful only for what a tap produces (in-flight, failed); whether the
/// account is linked comes from the caller, like every other value here.
class _AccountTile extends StatefulWidget {
  const _AccountTile({required this.signedIn, required this.onSignIn});

  final bool signedIn;
  final Future<void> Function() onSignIn;

  @override
  State<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<_AccountTile> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    var failed = false;
    try {
      await widget.onSignIn();
    } catch (_) {
      // Rendered on the row rather than reported: the user asked for this
      // and is looking at it, and an Apple sheet they dismissed themselves
      // arrives here too.
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.signedIn) {
      return ListTile(
        key: const ValueKey('settings_account_tile'),
        leading: const Icon(Icons.check_circle_outline),
        title: Text(l10n.settingsAccountSignedIn),
      );
    }
    return ListTile(
      key: const ValueKey('settings_account_tile'),
      leading: const Icon(Icons.apple),
      title: Text(l10n.settingsAccountSignIn),
      subtitle: _failed ? Text(l10n.settingsAccountSignInFailed) : null,
      trailing: const Icon(Icons.chevron_right),
      // Null while in flight: the Apple sheet takes a moment to appear, and
      // a second tap would start a second link.
      onTap: _busy ? null : _signIn,
    );
  }
}

/// The destructive counterpart to [_AccountTile] — not a sign-out: this
/// throws the uid away, along with everything hanging off it.
///
/// Stateful for the same reason [_AccountTile] is: what a tap produces
/// (in-flight, failed) belongs to the row, not to the caller.
class _DeleteAccountTile extends StatefulWidget {
  const _DeleteAccountTile({
    required this.onDelete,
    required this.credits,
    required this.onManageHosts,
    required this.hasHosts,
  });

  final Future<void> Function() onDelete;

  /// What the wallet holds, or zero while the balance is loading, failed or
  /// is genuinely empty — the dialog treats all three the same way.
  final int credits;

  final VoidCallback onManageHosts;

  /// Whether any host is configured on this device. The pre-delete dialog
  /// already warns that pairing goes with the account; this gates a second,
  /// actionable nudge right after deletion succeeds — skipped when there is
  /// nothing to re-pair.
  final bool hasHosts;

  @override
  State<_DeleteAccountTile> createState() => _DeleteAccountTileState();
}

class _DeleteAccountTileState extends State<_DeleteAccountTile> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _confirmAndDelete() async {
    if (await _showDeleteAccountDialog(context, widget.credits) != true) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    var failed = false;
    try {
      await widget.onDelete();
    } catch (_) {
      // Rendered on the row, like a failed sign-in: the user is looking at
      // it, and an Apple sheet they dismissed on the way arrives here too.
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = failed;
    });
    // Fired at the moment re-pairing actually matters, not just in the
    // pre-delete warning the user may have skimmed past.
    if (!failed && widget.hasHosts && mounted) {
      if (await _showAccountDeletedNotifyDialog(context) == true) {
        widget.onManageHosts();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = Theme.of(context).colorScheme.error;
    return ListTile(
      key: const ValueKey('settings_account_delete_tile'),
      leading: Icon(Icons.delete_forever, color: error),
      title: Text(l10n.settingsAccountDelete, style: TextStyle(color: error)),
      subtitle: _failed ? Text(l10n.accountDeleteFailed) : null,
      // Null while in flight: reauthentication, revoke and the callable are
      // several round trips, and a second tap would start a second delete.
      onTap: _busy ? null : _confirmAndDelete,
    );
  }
}

/// Asks before anything is destroyed, and says plainly what "everything"
/// covers — credits especially, since those were paid for and cannot come
/// back. Cancel is the default; the destructive action has to be chosen.
///
/// [credits] is named only when there is a number to name: a balance that is
/// zero, still loading or failed to load leaves the wording exactly as it was
/// before the client could read its own wallet at all.
Future<bool?> _showDeleteAccountDialog(BuildContext context, int credits) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final l10n = AppLocalizations.of(context)!;
      return AlertDialog(
        title: Text(l10n.accountDeleteTitle),
        content: Text(
          // A paragraph break rather than a space: the two are separate
          // sentences, and Japanese does not join sentences with one.
          credits > 0
              ? '${l10n.accountDeleteBody}\n\n'
                    '${l10n.accountDeleteBalance(credits)}'
              : l10n.accountDeleteBody,
        ),
        actions: [
          TextButton(
            key: const ValueKey('account_delete_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const ValueKey('account_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.accountDeleteConfirm),
          ),
        ],
      );
    },
  );
}

/// Follows a successful deletion when there was at least one host to
/// re-pair. The pre-delete dialog already discloses that pairing goes with
/// the account; this repeats it at the point where acting on it is actually
/// possible, with a direct route to the host list rather than a warning the
/// user has to remember and act on later.
Future<bool?> _showAccountDeletedNotifyDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final l10n = AppLocalizations.of(context)!;
      return AlertDialog(
        title: Text(l10n.accountDeletedTitle),
        content: Text(l10n.accountDeletedNotifyBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonClose),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.accountDeletedManageHosts),
          ),
        ],
      );
    },
  );
}

/// The reinstall recipe, as two copyable commands. No `-y` on either: the
/// install pulls executable code onto the host, so herdr's own confirmation
/// prompt stays in the loop — same call as the pairing dialog's install
/// command.
Future<void> _showPluginUpdateDialog(
  BuildContext context,
  StaleNotifyPlugin entry,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final l10n = AppLocalizations.of(context)!;
      final herdrBin = shellCommandPath(entry.herdrBin);
      return AlertDialog(
        title: Text(l10n.settingsNotifyPluginUpdateTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.settingsNotifyPluginUpdateIntro(
                  entry.hostName,
                  entry.installedVersion,
                ),
              ),
              const SizedBox(height: 16),
              CopyableValue(
                label: l10n.settingsNotifyPluginUninstallLabel,
                value: '$herdrBin plugin uninstall drover.notify',
              ),
              const SizedBox(height: 16),
              CopyableValue(
                label: l10n.settingsNotifyPluginInstallLabel,
                value: '$herdrBin plugin install keinstn/drover-notify',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonClose),
          ),
        ],
      );
    },
  );
}

/// The balance and the rows behind it, under the assistant switch.
///
/// A [FutureBuilder] builder rather than a widget: everything it renders is
/// one snapshot of a future the caller already started.
Widget _voiceCredits(BuildContext context, AsyncSnapshot<VoiceWallet> snap) {
  final l10n = AppLocalizations.of(context)!;
  final scheme = Theme.of(context).colorScheme;
  if (snap.hasError) {
    return ListTile(
      key: const ValueKey('settings_voice_credits_failed_tile'),
      leading: const Icon(Icons.toll_outlined),
      title: Text(l10n.settingsVoiceCreditsFailed),
    );
  }
  final wallet = snap.data;
  // Nothing at all while it is in flight. A spinner would take up a row's
  // worth of height and then hand it back, shifting everything below it just
  // as the user reaches for a switch.
  if (wallet == null) return const SizedBox.shrink();
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        key: const ValueKey('settings_voice_credits_tile'),
        leading: const Icon(Icons.toll_outlined),
        title: Text(l10n.settingsVoiceCredits),
        subtitle: Text(l10n.settingsVoiceCreditsSubtitle),
        // No chevron and no tap: there is nothing to buy yet, and a row that
        // leads nowhere is worse than one that plainly just reports.
        trailing: Text(
          '${wallet.credits}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
      _sectionHeader(context, l10n.settingsVoiceCreditsActivity),
      if (wallet.entries.isEmpty)
        ListTile(
          key: const ValueKey('settings_voice_credits_none_tile'),
          title: Text(
            l10n.settingsVoiceCreditsNone,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      for (final (index, entry) in wallet.entries.indexed)
        ListTile(
          key: ValueKey('settings_voice_credits_entry_$index'),
          title: Text(switch (entry.type) {
            VoiceLedgerType.call => l10n.voiceLedgerCall,
            VoiceLedgerType.refund => l10n.voiceLedgerRefund,
          }),
          // No line at all when the row came back without a usable date:
          // an empty subtitle would still take up the space.
          subtitle: switch (entry.at) {
            final at? => Text(_ledgerTimestamp(context, at)),
            null => null,
          },
          trailing: Text(
            _signedCredits(entry.credits),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
    ],
  );
}

/// The framework's own date and time for the active locale. Nothing else in
/// the app renders an absolute timestamp — the herd screen speaks in elapsed
/// time — so there is no house format to match, and
/// [MaterialLocalizations] already follows both the locale and the device's
/// 24-hour setting.
String _ledgerTimestamp(BuildContext context, DateTime at) {
  final material = MaterialLocalizations.of(context);
  return '${material.formatShortDate(at)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(at))}';
}

/// Always signed, because which way a row moved the balance is the whole
/// point of showing it. A true minus rather than a hyphen, to line up with
/// the plus.
String _signedCredits(int credits) =>
    credits < 0 ? '\u2212${-credits}' : '+$credits';

Widget _sectionHeader(BuildContext context, String label) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
  child: Text(
    droverLabelText(context, label),
    // Not the accent: under ink that is body-text colour, and a section
    // header has to read quieter than what it labels. Same treatment as the
    // herd screen's workspace headers.
    style: droverLabelStyle(
      context,
      color: DroverColors.of(context).tertiaryText,
    ),
  ),
);

String _themeModeLabel(AppLocalizations l10n, ThemeMode mode) => switch (mode) {
  ThemeMode.system => l10n.settingsThemeSystem,
  ThemeMode.light => l10n.settingsThemeLight,
  ThemeMode.dark => l10n.settingsThemeDark,
};

// The system option is localized; 日本語/English are hardcoded literals (not
// l10n strings) so a user who picked a language they can't read can still
// find their way back to the row that lets them change it.
String _localeLabel(AppLocalizations l10n, Locale? locale) =>
    switch (locale?.languageCode) {
      'ja' => '日本語',
      'en' => 'English',
      _ => l10n.settingsLanguageSystem,
    };

Future<void> _showThemeSheet(
  BuildContext context, {
  required ThemeMode current,
  required ValueChanged<ThemeMode> onSelect,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<void>(
    context: context,
    // _OptionSheet paints its own panel; without this the host sheet's
    // 28-radius shell peeks around its 6-radius corners.
    backgroundColor: Colors.transparent,
    builder: (context) => _OptionSheet(
      title: l10n.settingsTheme,
      options: [
        _option(
          context,
          key: const ValueKey('settings_theme_option_system'),
          label: l10n.settingsThemeSystem,
          selected: current == ThemeMode.system,
          onTap: () {
            Navigator.pop(context);
            onSelect(ThemeMode.system);
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_theme_option_light'),
          label: l10n.settingsThemeLight,
          selected: current == ThemeMode.light,
          onTap: () {
            Navigator.pop(context);
            onSelect(ThemeMode.light);
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_theme_option_dark'),
          label: l10n.settingsThemeDark,
          selected: current == ThemeMode.dark,
          onTap: () {
            Navigator.pop(context);
            onSelect(ThemeMode.dark);
          },
        ),
      ],
    ),
  );
}

Future<void> _showLanguageSheet(
  BuildContext context, {
  required Locale? current,
  required ValueChanged<Locale?> onSelect,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _OptionSheet(
      title: l10n.settingsLanguage,
      options: [
        _option(
          context,
          key: const ValueKey('settings_language_option_system'),
          label: l10n.settingsLanguageSystem,
          selected: current == null,
          onTap: () {
            Navigator.pop(context);
            onSelect(null);
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_language_option_ja'),
          label: '日本語',
          selected: current?.languageCode == 'ja',
          onTap: () {
            Navigator.pop(context);
            onSelect(const Locale('ja'));
          },
        ),
        _option(
          context,
          key: const ValueKey('settings_language_option_en'),
          label: 'English',
          selected: current?.languageCode == 'en',
          onTap: () {
            Navigator.pop(context);
            onSelect(const Locale('en'));
          },
        ),
      ],
    ),
  );
}

/// Shared bottom-sheet chrome for a radio-style option list: rounded top +
/// grab handle + `titleLarge` header, same visual pattern as
/// `host_switcher_sheet.dart`. [options] are pre-built rows (see [_option]);
/// each already pops the sheet before invoking its own callback.
class _OptionSheet extends StatelessWidget {
  const _OptionSheet({required this.title, required this.options});

  final String title;
  final List<Widget> options;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      // The flat ink surfaces need the hairline to separate the sheet from
      // the page behind it.
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(droverRadiusLarge),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: ShapeDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 8),
              ...options,
            ],
          ),
        ),
      ),
    );
  }
}

/// One radio-style row shared by both sheets.
Widget _option(
  BuildContext context, {
  required Key key,
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  final scheme = Theme.of(context).colorScheme;
  return ListTile(
    key: key,
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      // Selection marks use the accent as text, not as a fill.
      color: selected
          ? DroverColors.of(context).accentText
          : scheme.onSurfaceVariant,
    ),
    title: Text(label),
    onTap: onTap,
  );
}
