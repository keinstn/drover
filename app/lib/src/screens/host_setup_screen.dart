import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../models/host_config.dart';
import '../models/plugin_info.dart';
import '../notifications/host_pairing.dart';
import '../widgets/error_message_view.dart';

/// Form for entering (or editing) the SSH connection details for the dev
/// machine running Herdr.
class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({
    super.key,
    this.initial,
    required this.onSubmit,
    this.onTest,
    this.onCreatePairingCode,
    this.onDetectPlugin,
    this.onAutoPair,
  });

  final HostConfig? initial;
  final Future<void> Function(HostConfig) onSubmit;
  final Future<String> Function(HostConfig)? onTest;
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
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _userController;
  late final TextEditingController _keyController;
  late final TextEditingController _passphraseController;
  late final TextEditingController _herdrBinController;
  late String? _hostId;

  bool _busy = false;
  String? _statusMessage;
  Object? _statusError;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
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
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _keyController.dispose();
    _passphraseController.dispose();
    _herdrBinController.dispose();
    super.dispose();
  }

  /// Whether the host currently described by the form has connected
  /// successfully before, for picking the right connection-error message.
  /// True only when editing a host ([widget.initial] non-null with a pinned
  /// fingerprint) AND the address/port haven't been changed since — an
  /// edited address/port reopens "maybe it's just wrong", which the pinned
  /// fingerprint (from the OLD address) can't rule out.
  bool get _hostEverConnected {
    final initial = widget.initial;
    if (initial == null || initial.hostKeyFingerprint == null) return false;
    final port = int.tryParse(_portController.text.trim()) ?? 22;
    return _hostController.text.trim() == initial.host && port == initial.port;
  }

  HostConfig? _buildConfig() {
    if (!(_formKey.currentState?.validate() ?? false)) return null;
    final passphrase = _passphraseController.text;
    final name = _nameController.text.trim();
    return HostConfig(
      name: name.isEmpty ? null : name,
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
      _statusError = null;
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
        _statusError = error;
        _statusMessage = null;
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
      setState(() {
        _statusError = error;
        _statusMessage = null;
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
      _statusError = null;
    });
    try {
      final result = await onTest(config);
      if (!mounted) return;
      setState(() {
        _statusMessage = result;
        _statusError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusError = e;
        _statusMessage = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleSave() async {
    final config = _buildConfig();
    if (config == null) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
      _statusError = null;
    });
    try {
      await widget.onSubmit(config);
      if (!mounted) return;
      setState(() => _busy = false);
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusError = e;
        _statusMessage = null;
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
              controller: _nameController,
              decoration: InputDecoration(labelText: l10n.hostSetupNameLabel),
            ),
            const SizedBox(height: 12),
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
              // Blank is allowed and defaults to 22 (see _buildConfig); only a
              // non-blank value has to be a valid port number.
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return null;
                final port = int.tryParse(t);
                if (port == null || port < 1 || port > 65535) {
                  return l10n.hostSetupPortInvalid;
                }
                return null;
              },
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
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return l10n.hostSetupPrivateKeyRequired;
                if (!_looksLikePrivateKeyPem(t)) {
                  return l10n.hostSetupPrivateKeyInvalid;
                }
                return null;
              },
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
            if (_statusError != null) ...[
              ErrorMessageView(
                _statusError!,
                hostEverConnected: _hostEverConnected,
              ),
              const SizedBox(height: 12),
            ] else if (_statusMessage != null) ...[
              Text(
                _statusMessage!,
                style: TextStyle(color: DroverColors.of(context).donePillFg),
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
          ],
        ),
      ),
    );
  }
}

// Lenient structural check for a PEM private key: a matching BEGIN/END pair
// of any key type (RSA/EC/OPENSSH/PKCS#8). Deliberately does NOT parse the
// key — an encrypted key can't be parsed here without the passphrase, which
// isn't entered yet. This just catches the common paste mistakes (a public
// key, or a truncated block) before the connection attempt.
final _privateKeyPemPattern = RegExp(
  r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]+-----END [A-Z0-9 ]*PRIVATE KEY-----',
);

bool _looksLikePrivateKeyPem(String value) =>
    _privateKeyPemPattern.hasMatch(value);

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
