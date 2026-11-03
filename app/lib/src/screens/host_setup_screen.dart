import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../herdr/herdr_backend.dart';
import '../infra/host_connections.dart';
import '../infra/shell_command.dart';
import '../models/host_config.dart';
import '../models/plugin_info.dart';
import '../notifications/host_pairing.dart';
import '../widgets/copyable_value.dart';
import '../widgets/error_message_view.dart';
import '../widgets/text_context_menu.dart';

/// Form for entering (or editing) the SSH connection details for the dev
/// machine running Herdr.
class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({
    super.key,
    this.initial,
    required this.onSubmit,
    this.onTest,
    this.onProbeHcOnly,
    this.onCreatePairingCode,
    this.onDetectPlugin,
    this.onAutoPair,
    this.onEnterDemo,
  });

  final HostConfig? initial;
  final Future<void> Function(HostConfig) onSubmit;
  final Future<String> Function(HostConfig)? onTest;

  /// Reports whether the host has Herdr 2's `hc` but no herdr 1. Asked before
  /// a connection test of a NEW host still set to herdr 1, so a Herdr 2 user
  /// who left the default is switched over instead of failing the test.
  final Future<bool> Function(HostConfig)? onProbeHcOnly;
  final Future<PairingCode> Function(HostConfig)? onCreatePairingCode;

  /// Enters the scripted demo session. Non-null only on the first-run
  /// instance of this screen (not the routes pushed to add/edit a host) —
  /// the demo is an intro for someone with no host yet, not an option to
  /// surface while already managing one.
  final VoidCallback? onEnterDemo;

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
  late HerdrBackend _backend;
  bool _hcDetected = false;

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
    _backend = initial?.backend ?? HerdrBackend.herdr;
    _herdrBinController = TextEditingController(
      text: initial?.herdrBin ?? defaultBinFor(_backend),
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

  /// Switches the backend and resets the bin field to its default: a path
  /// for one CLI is never right for the other.
  void _selectBackend(HerdrBackend backend) {
    _herdrBinController.text = defaultBinFor(backend);
    setState(() {
      _backend = backend;
      _hcDetected = false;
    });
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
          ? defaultBinFor(_backend)
          : _herdrBinController.text.trim(),
      hostId: _hostId,
      backend: _backend,
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
        final herdrBin = shellCommandPath(config.herdrBin);
        // `plugin install` clones from GitHub, so there is no checkout path for
        // the user to substitute, and the install location is herdr's to
        // choose — which is why no setup command is offered here. Once the
        // plugin is installed, [_detectPlugin] finds it and pairing runs
        // automatically; the code and URL below are only for pairing by hand.
        final installCommand = '$herdrBin plugin install keinstn/drover-notify';
        return AlertDialog(
          title: Text(l10n.hostPairingCodeTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.hostPairingCodeIntro),
                const SizedBox(height: 16),
                CopyableValue(
                  key: const ValueKey('pairing_install_command'),
                  label: l10n.hostPairingInstallCommandLabel,
                  value: installCommand,
                ),
                const SizedBox(height: 16),
                Text(l10n.hostPairingManualNote),
                const SizedBox(height: 16),
                CopyableValue(
                  label: l10n.hostPairingCodeLabel,
                  value: pairing.code,
                ),
                const SizedBox(height: 16),
                CopyableValue(
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
      String result;
      try {
        result = await onTest(config);
      } catch (e) {
        if (!isHerdrBinaryMissing(e)) rethrow;
        final hcConfig = await _switchIfHcOnly(config);
        if (hcConfig == null) rethrow;
        result = await onTest(hcConfig);
      }
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

  /// After a test of a NEW herdr 1 host on the default path failed because
  /// `herdr` wasn't found: if the host has only Herdr 2's `hc`, switches the
  /// form to Herdr 2 and returns the config to re-test with; otherwise null
  /// (the original failure stands). A custom herdr path means the user chose
  /// herdr 1.
  Future<HostConfig?> _switchIfHcOnly(HostConfig config) async {
    final onProbeHcOnly = widget.onProbeHcOnly;
    if (onProbeHcOnly == null ||
        widget.initial != null ||
        config.backend != HerdrBackend.herdr ||
        config.herdrBin != kDefaultHerdrBin) {
      return null;
    }
    final hcOnly = await onProbeHcOnly(config).catchError((_) => false);
    if (!hcOnly || !mounted) return null;
    _selectBackend(HerdrBackend.hc);
    setState(() => _hcDetected = true);
    return _buildConfig();
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hostSetupTitle)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.onEnterDemo != null) ...[
              Card(
                // The flat ink surfaces need the hairline to separate the
                // card from the page behind it.
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(droverRadiusLarge),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.hostSetupDemoIntro),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: const ValueKey('enter_demo_button'),
                        style: droverNeutralButtonStyle(scheme),
                        onPressed: widget.onEnterDemo,
                        child: Text(l10n.hostSetupDemoButton),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(labelText: l10n.hostSetupNameLabel),
              contextMenuBuilder: noScanTextContextMenuBuilder,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _hostController,
              decoration: InputDecoration(labelText: l10n.hostSetupHostLabel),
              contextMenuBuilder: noScanTextContextMenuBuilder,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.hostSetupHostRequired
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _portController,
              decoration: InputDecoration(labelText: l10n.hostSetupPortLabel),
              keyboardType: TextInputType.number,
              contextMenuBuilder: noScanTextContextMenuBuilder,
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
              contextMenuBuilder: noScanTextContextMenuBuilder,
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
              style: const TextStyle(
                fontFamily: droverMonoFamily,
                fontFeatures: droverMonoFeatures,
              ),
              maxLines: 6,
              contextMenuBuilder: noScanTextContextMenuBuilder,
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
              contextMenuBuilder: noScanTextContextMenuBuilder,
            ),
            const SizedBox(height: 12),
            // One list child, so the notes appearing doesn't shift the
            // ExpansionTile's index and reset its expanded state.
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.hostSetupBackendLabel),
                const SizedBox(height: 8),
                SegmentedButton<HerdrBackend>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: HerdrBackend.herdr,
                      label: Text(l10n.hostSetupBackendHerdr1),
                    ),
                    ButtonSegment(
                      value: HerdrBackend.hc,
                      label: Text(l10n.hostSetupBackendHerdr2),
                    ),
                  ],
                  selected: {_backend},
                  onSelectionChanged: _busy
                      ? null
                      : (values) => _selectBackend(values.first),
                ),
                if (_backend == HerdrBackend.hc) ...[
                  const SizedBox(height: 8),
                  if (_hcDetected) ...[
                    Text(
                      l10n.hostSetupHcDetected,
                      key: const ValueKey('host_setup_hc_detected'),
                      style: TextStyle(
                        color: DroverColors.of(context).donePillFg,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    l10n.hostSetupHerdr2Note,
                    key: const ValueKey('host_setup_herdr2_note'),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: Text(l10n.hostSetupAdvanced),
              tilePadding: EdgeInsets.zero,
              children: [
                TextFormField(
                  controller: _herdrBinController,
                  decoration: InputDecoration(
                    labelText: _backend == HerdrBackend.hc
                        ? l10n.hostSetupHcBinLabel
                        : l10n.hostSetupHerdrBinLabel,
                  ),
                  contextMenuBuilder: noScanTextContextMenuBuilder,
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Herdr 2 has no plugins, so there is nothing to pair.
            // Pairing acts on the saved host, so both must be herdr 1.
            if (widget.onCreatePairingCode != null &&
                widget.initial?.backend == HerdrBackend.herdr &&
                _backend == HerdrBackend.herdr) ...[
              OutlinedButton(
                style: droverNeutralButtonStyle(scheme),
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
                      style: droverNeutralButtonStyle(scheme),
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
                    child: Text(
                      droverLabelText(context, l10n.hostSetupSave),
                      style: droverLabelStyle(
                        context,
                        fontSize: 11.5,
                        weight: FontWeight.w700,
                      ),
                    ),
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
