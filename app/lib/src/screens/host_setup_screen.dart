import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/host_config.dart';
import '../models/plugin_info.dart';
import '../notifications/host_pairing.dart';

/// Form for entering (or editing) the SSH connection details for the dev
/// machine running Herdr.
class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({
    super.key,
    this.initial,
    required this.onSubmit,
    this.onTest,
    this.onReset,
    this.onCreatePairingCode,
    this.onDetectPlugin,
    this.onAutoPair,
  });

  final HostConfig? initial;
  final Future<void> Function(HostConfig) onSubmit;
  final Future<String> Function(HostConfig)? onTest;

  /// Clears the stored host config and returns to first-run setup. When null,
  /// the reset control is hidden (e.g. during first-run setup).
  final Future<void> Function()? onReset;
  final Future<PairingCode> Function(HostConfig)? onCreatePairingCode;

  /// Detects whether the `drover.notify` plugin is already linked and
  /// enabled on the host. Returning null (including on detection failure)
  /// falls back to the manual pairing dialog. When null, pairing always
  /// goes through the manual dialog, same as before this capability existed.
  final Future<PluginInfo?> Function(HostConfig)? onDetectPlugin;

  /// Drives the already-linked plugin's own pairing script over SSH. Only
  /// called after the user confirms the auto-pair dialog.
  final Future<void> Function(HostConfig, PluginInfo, PairingCode)? onAutoPair;

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _userController;
  late final TextEditingController _keyController;
  late final TextEditingController _passphraseController;
  late final TextEditingController _herdrBinController;
  late String? _hostId;

  bool _busy = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _hostController = TextEditingController(text: initial?.host ?? '');
    _portController = TextEditingController(text: '${initial?.port ?? 22}');
    _userController = TextEditingController(text: initial?.user ?? '');
    _keyController = TextEditingController(text: initial?.privateKeyPem ?? '');
    _passphraseController = TextEditingController(
      text: initial?.passphrase ?? '',
    );
    _herdrBinController = TextEditingController(
      text: initial?.herdrBin ?? kDefaultHerdrBin,
    );
    _hostId = initial?.hostId;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _keyController.dispose();
    _passphraseController.dispose();
    _herdrBinController.dispose();
    super.dispose();
  }

  HostConfig? _buildConfig() {
    if (!(_formKey.currentState?.validate() ?? false)) return null;
    final passphrase = _passphraseController.text;
    return HostConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 22,
      user: _userController.text.trim(),
      privateKeyPem: _keyController.text,
      passphrase: passphrase.isEmpty ? null : passphrase,
      herdrBin: _herdrBinController.text.trim().isEmpty
          ? kDefaultHerdrBin
          : _herdrBinController.text.trim(),
      hostId: _hostId,
    );
  }

  Future<void> _createPairingCode() async {
    final onCreatePairingCode = widget.onCreatePairingCode;
    if (onCreatePairingCode == null) return;
    final config = widget.initial;
    if (config == null) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final plugin = await _detectPlugin(config);
      if (plugin != null && await _confirmAutoPair()) {
        final pairing = await onCreatePairingCode(config);
        if (!mounted) return;
        setState(() => _hostId = pairing.hostId);
        await _autoPairOrFallBackToManual(config, plugin, pairing);
        return;
      }
      final pairing = await onCreatePairingCode(config);
      if (!mounted) return;
      setState(() {
        _hostId = pairing.hostId;
        _busy = false;
      });
      await _showManualPairingDialog(config, pairing);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = error.toString();
        _statusIsError = true;
        _busy = false;
      });
    }
  }

  Future<PluginInfo?> _detectPlugin(HostConfig config) async {
    final onDetectPlugin = widget.onDetectPlugin;
    if (onDetectPlugin == null) return null;
    try {
      return await onDetectPlugin(config);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _confirmAutoPair() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.hostPairAutoDetectedTitle),
        content: Text(l10n.hostPairAutoDetectedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.hostPairAutoDetectedConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _autoPairOrFallBackToManual(
    HostConfig config,
    PluginInfo plugin,
    PairingCode pairing,
  ) async {
    final onAutoPair = widget.onAutoPair;
    try {
      if (onAutoPair == null) {
        throw StateError('Auto-pairing is unavailable.');
      }
      await onAutoPair(config, plugin, pairing);
      if (!mounted) return;
      setState(() => _busy = false);
      await _showAutoPairSuccessDialog();
    } catch (error) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _statusMessage = l10n.hostPairAutoFailedStatus(error.toString());
        _statusIsError = true;
        _busy = false;
      });
      await _showManualPairingDialog(config, pairing);
    }
  }

  Future<void> _showAutoPairSuccessDialog() {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.hostPairAutoPairedTitle),
        content: Text(l10n.hostPairAutoPairedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  Future<void> _showManualPairingDialog(
    HostConfig config,
    PairingCode pairing,
  ) {
    return showDialog<void>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        final pluginPath = '/path/to/drover/plugins/drover-notify';
        final herdrBin = _shellCommandPath(config.herdrBin);
        final linkCommand = '$herdrBin plugin link $pluginPath';
        final setupCommand =
            'node $pluginPath/bin/setup.mjs --completion-url '
            '${_shellQuote(pairing.completionUrl)} --herdr-bin $herdrBin';
        return AlertDialog(
          title: Text(l10n.hostPairingCodeTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.hostPairingCodeIntro),
                const SizedBox(height: 16),
                _CopyableValue(
                  label: l10n.hostPairingLinkCommandLabel,
                  value: linkCommand,
                ),
                const SizedBox(height: 16),
                _CopyableValue(
                  label: l10n.hostPairingSetupCommandLabel,
                  value: setupCommand,
                ),
                const SizedBox(height: 16),
                _CopyableValue(
                  label: l10n.hostPairingCodeLabel,
                  value: pairing.code,
                ),
                const SizedBox(height: 16),
                _CopyableValue(
                  label: l10n.hostPairingUrlLabel,
                  value: pairing.completionUrl,
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

  Future<void> _handleTest() async {
    final onTest = widget.onTest;
    if (onTest == null) return;
    final config = _buildConfig();
    if (config == null) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final result = await onTest(config);
      if (!mounted) return;
      setState(() {
        _statusMessage = result;
        _statusIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = e.toString();
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleReset() async {
    final onReset = widget.onReset;
    if (onReset == null) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.hostResetDialogTitle),
        content: Text(l10n.hostResetDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonReset),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await onReset();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = e.toString();
        _statusIsError = true;
        _busy = false;
      });
    }
  }

  Future<void> _handleSave() async {
    final config = _buildConfig();
    if (config == null) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      await widget.onSubmit(config);
      if (!mounted) return;
      setState(() => _busy = false);
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = e.toString();
        _statusIsError = true;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hostSetupTitle)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _hostController,
              decoration: InputDecoration(labelText: l10n.hostSetupHostLabel),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.hostSetupHostRequired
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _portController,
              decoration: InputDecoration(labelText: l10n.hostSetupPortLabel),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _userController,
              decoration: InputDecoration(labelText: l10n.hostSetupUserLabel),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.hostSetupUserRequired
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _keyController,
              decoration: InputDecoration(
                labelText: l10n.hostSetupPrivateKeyLabel,
              ),
              style: const TextStyle(fontFamily: 'monospace'),
              maxLines: 6,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.hostSetupPrivateKeyRequired
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passphraseController,
              decoration: InputDecoration(
                labelText: l10n.hostSetupPassphraseLabel,
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: Text(l10n.hostSetupAdvanced),
              tilePadding: EdgeInsets.zero,
              children: [
                TextFormField(
                  controller: _herdrBinController,
                  decoration: InputDecoration(
                    labelText: l10n.hostSetupHerdrBinLabel,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (widget.onCreatePairingCode != null) ...[
              OutlinedButton(
                onPressed: _busy ? null : _createPairingCode,
                child: Text(l10n.hostPairNotifications),
              ),
              const SizedBox(height: 12),
            ],
            if (_statusMessage != null) ...[
              Text(
                _statusMessage!,
                style: TextStyle(
                  color: _statusIsError
                      ? Theme.of(context).colorScheme.error
                      : Colors.green,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                if (widget.onTest != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _handleTest,
                      child: _busy
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.hostSetupTestConnection),
                    ),
                  ),
                if (widget.onTest != null) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _handleSave,
                    child: Text(l10n.hostSetupSave),
                  ),
                ),
              ],
            ),
            if (widget.onReset != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy ? null : _handleReset,
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: Text(l10n.hostSetupResetButton),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _shellCommandPath(String value) => value.startsWith('~/')
    ? '\$HOME/${_shellQuote(value.substring(2))}'
    : _shellQuote(value);

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

class _CopyableValue extends StatelessWidget {
  const _CopyableValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            IconButton(
              tooltip: l10n.commonCopy,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
          ],
        ),
      ],
    );
  }
}
