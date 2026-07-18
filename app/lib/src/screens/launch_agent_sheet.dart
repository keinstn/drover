import 'package:flutter/material.dart';

import '../herdr/herdr_client.dart';
import '../models/agent_preset.dart';
import '../models/claude_permission_mode.dart';
import '../models/workspace_info.dart';
import '../utils/path.dart';

enum _WorkspaceMode { newWorkspace, existing }

/// Sheet body for launching a new agent: pick a preset, a cwd, and whether to
/// place it in a new or existing workspace.
class LaunchAgentSheet extends StatefulWidget {
  const LaunchAgentSheet({
    super.key,
    required this.client,
    required this.existingCwds,
  });

  final HerdrClient client;
  final List<String> existingCwds;

  @override
  State<LaunchAgentSheet> createState() => _LaunchAgentSheetState();
}

class _LaunchAgentSheetState extends State<LaunchAgentSheet> {
  late Future<List<AgentPreset>> _presetsFuture;
  Future<List<WorkspaceInfo>>? _workspacesFuture;

  AgentPreset? _selectedPreset;
  ClaudePermissionMode _permissionMode = ClaudePermissionMode.defaultMode;
  final _cwdController = TextEditingController();
  _WorkspaceMode _mode = _WorkspaceMode.newWorkspace;
  String? _selectedWorkspaceId;
  bool _busy = false;
  String? _launchError;

  @override
  void initState() {
    super.initState();
    _detectAgents();
  }

  @override
  void dispose() {
    _cwdController.dispose();
    super.dispose();
  }

  void _detectAgents() {
    final future = widget.client.detectAgents(kAgentPresets);
    _presetsFuture = future;
    future.then((presets) {
      if (!mounted) return;
      if (_selectedPreset == null && presets.isNotEmpty) {
        setState(() => _selectedPreset = presets.first);
      }
    }, onError: (_) {}); // FutureBuilder renders the error; swallow here to
    // avoid an unhandled rejection
  }

  void _loadWorkspaces() {
    final future = widget.client.listWorkspaces();
    _workspacesFuture = future;
    future.then((workspaces) {
      if (!mounted) return;
      if (_selectedWorkspaceId != null &&
          !workspaces.any((w) => w.workspaceId == _selectedWorkspaceId)) {
        setState(() => _selectedWorkspaceId = null);
      }
    }, onError: (_) {});
  }

  bool get _canLaunch {
    if (_busy) return false;
    if (_selectedPreset == null) return false;
    if (_cwdController.text.trim().isEmpty) return false;
    if (_mode == _WorkspaceMode.existing && _selectedWorkspaceId == null) {
      return false;
    }
    return true;
  }

  Future<void> _launch() async {
    final preset = _selectedPreset;
    if (preset == null) return;
    final cwd = _cwdController.text.trim();
    if (cwd.isEmpty) return;
    if (_mode == _WorkspaceMode.existing && _selectedWorkspaceId == null) {
      return;
    }

    setState(() {
      _busy = true;
      _launchError = null;
    });
    try {
      final seg = lastPathSegment(cwd);
      final name = seg.isEmpty ? preset.bin : seg;
      final wsId = _mode == _WorkspaceMode.newWorkspace
          ? await widget.client.createWorkspace(label: name, cwd: cwd)
          : _selectedWorkspaceId!;
      try {
        await widget.client.startAgent(
          name: name,
          argv: launchArgv(preset, _permissionMode),
          cwd: cwd,
          workspaceId: wsId,
        );
      } catch (e) {
        if (_mode == _WorkspaceMode.newWorkspace) {
          try {
            await widget.client.closeWorkspace(wsId);
          } catch (_) {}
        }
        rethrow;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _launchError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Launch agent',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              _buildPresetSection(),
              if (_selectedPreset?.isClaude ?? false) ...[
                const SizedBox(height: 16),
                _buildPermissionModeSection(),
              ],
              const SizedBox(height: 16),
              _buildCwdSection(),
              const SizedBox(height: 16),
              _buildWorkspaceSection(),
              if (_launchError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _launchError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('launch_button'),
                  onPressed: _canLaunch ? _launch : null,
                  child: _busy
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Launch'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetSection() {
    return FutureBuilder<List<AgentPreset>>(
      future: _presetsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snapshot.error.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: () => setState(_detectAgents),
                child: const Text('Retry'),
              ),
            ],
          );
        }
        final presets = snapshot.data ?? [];
        if (presets.isEmpty) {
          return const Text('No launchable agents found on the host');
        }
        return RadioGroup<AgentPreset>(
          groupValue: _selectedPreset,
          onChanged: (value) {
            if (_busy) return;
            setState(() {
              _selectedPreset = value;
              if (!(value?.isClaude ?? false)) {
                _permissionMode = ClaudePermissionMode.defaultMode;
              }
            });
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final preset in presets)
                RadioListTile<AgentPreset>(
                  key: ValueKey('preset_${preset.bin}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(preset.label),
                  value: preset,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPermissionModeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Permission mode'),
        DropdownButton<ClaudePermissionMode>(
          key: const ValueKey('permission_mode_dropdown'),
          value: _permissionMode,
          items: [
            for (final mode in ClaudePermissionMode.values)
              DropdownMenuItem(value: mode, child: Text(mode.label)),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) {
                    setState(() => _permissionMode = value);
                  }
                },
        ),
      ],
    );
  }

  Widget _buildCwdSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.existingCwds.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final cwd in widget.existingCwds)
                ActionChip(
                  label: Text(lastPathSegment(cwd)),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _cwdController.text = cwd),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          key: const ValueKey('cwd_field'),
          controller: _cwdController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Working directory',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  void _selectMode(_WorkspaceMode mode) {
    if (_busy) return;
    setState(() {
      _mode = mode;
      if (_mode == _WorkspaceMode.existing && _workspacesFuture == null) {
        _loadWorkspaces();
      }
    });
  }

  Widget _buildWorkspaceSection() {
    return RadioGroup<_WorkspaceMode>(
      groupValue: _mode,
      onChanged: (value) {
        if (value != null) _selectMode(value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RadioListTile<_WorkspaceMode>(
            key: const ValueKey('ws_mode_new'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('New workspace'),
            value: _WorkspaceMode.newWorkspace,
          ),
          RadioListTile<_WorkspaceMode>(
            key: const ValueKey('ws_mode_existing'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Existing workspace'),
            value: _WorkspaceMode.existing,
          ),
          if (_mode == _WorkspaceMode.existing) ...[
            const SizedBox(height: 12),
            _buildWorkspaceDropdown(),
          ],
        ],
      ),
    );
  }

  Widget _buildWorkspaceDropdown() {
    return FutureBuilder<List<WorkspaceInfo>>(
      future: _workspacesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snapshot.error.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(_loadWorkspaces),
                    child: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _mode = _WorkspaceMode.newWorkspace;
                    }),
                    child: const Text('Use new workspace instead'),
                  ),
                ],
              ),
            ],
          );
        }
        final workspaces = snapshot.data ?? [];
        if (workspaces.isEmpty) {
          return const Text('No existing workspaces');
        }
        return DropdownButton<String>(
          key: const ValueKey('ws_dropdown'),
          isExpanded: true,
          hint: const Text('Select workspace'),
          value: _selectedWorkspaceId,
          items: [
            for (final ws in workspaces)
              DropdownMenuItem(
                value: ws.workspaceId,
                child: Text('${ws.label} (${ws.workspaceId})'),
              ),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() => _selectedWorkspaceId = value),
        );
      },
    );
  }
}
