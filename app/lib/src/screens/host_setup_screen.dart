import 'package:flutter/material.dart';

import '../models/host_config.dart';

/// Form for entering (or editing) the SSH connection details for the dev
/// machine running Herdr.
class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({
    super.key,
    this.initial,
    required this.onSubmit,
    this.onTest,
    this.onReset,
  });

  final HostConfig? initial;
  final Future<void> Function(HostConfig) onSubmit;
  final Future<String> Function(HostConfig)? onTest;

  /// Clears the stored host config and returns to first-run setup. When null,
  /// the reset control is hidden (e.g. during first-run setup).
  final Future<void> Function()? onReset;

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

  bool _busy = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _hostController = TextEditingController(text: initial?.host ?? '');
    _portController = TextEditingController(
      text: '${initial?.port ?? 22}',
    );
    _userController = TextEditingController(text: initial?.user ?? '');
    _keyController = TextEditingController(
      text: initial?.privateKeyPem ?? '',
    );
    _passphraseController = TextEditingController(
      text: initial?.passphrase ?? '',
    );
    _herdrBinController = TextEditingController(
      text: initial?.herdrBin ?? kDefaultHerdrBin,
    );
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset host?'),
        content: const Text(
          'This deletes the saved connection details (including the SSH key) '
          'and returns to the setup screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Host setup')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _hostController,
              decoration: const InputDecoration(labelText: 'Host'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Host is required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _portController,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _userController,
              decoration: const InputDecoration(labelText: 'User'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'User is required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _keyController,
              decoration: const InputDecoration(
                labelText: 'Private key PEM',
              ),
              style: const TextStyle(fontFamily: 'monospace'),
              maxLines: 6,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Private key is required'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passphraseController,
              decoration: const InputDecoration(labelText: 'Passphrase'),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('Advanced'),
              tilePadding: EdgeInsets.zero,
              children: [
                TextFormField(
                  controller: _herdrBinController,
                  decoration: const InputDecoration(
                    labelText: 'Herdr binary path',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
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
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Text('Test connection'),
                    ),
                  ),
                if (widget.onTest != null) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _handleSave,
                    child: const Text('Save'),
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
                child: const Text('Reset host'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
