import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../herdr/herdr_client.dart';
import '../models/agent_preset.dart';
import '../models/workspace_info.dart';
import '../utils/path.dart';
import '../widgets/error_message_view.dart';
import '../widgets/text_context_menu.dart';
import 'directory_picker_sheet.dart';

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
  final _formKey = GlobalKey<FormState>();
  late Future<List<AgentPreset>> _presetsFuture;
  Future<List<WorkspaceInfo>>? _workspacesFuture;

  AgentPreset? _selectedPreset;
  final _cwdController = TextEditingController();
  final _nameController = TextEditingController();
  final _workspaceNameController = TextEditingController();
  bool _nameEdited = false;
  bool _workspaceNameEdited = false;
  _WorkspaceMode _mode = _WorkspaceMode.newWorkspace;
  String? _selectedWorkspaceId;
  bool _busy = false;
  Object? _launchError;

  @override
  void initState() {
    super.initState();
    _detectAgents();
  }

  @override
  void dispose() {
    _cwdController.dispose();
    _nameController.dispose();
    _workspaceNameController.dispose();
    super.dispose();
  }

  void _detectAgents() {
    final future = widget.client.detectAgents(kAgentPresets);
    _presetsFuture = future;
    future.then((presets) {
      if (!mounted) return;
      if (_selectedPreset == null && presets.isNotEmpty) {
        setState(() {
          _selectedPreset = presets.first;
          _syncDefaultName();
        });
      }
    }, onError: (_) {}); // FutureBuilder renders the error; swallow here to
    // avoid an unhandled rejection
  }

  String _defaultName() {
    final seg = lastPathSegment(_cwdController.text.trim());
    final bin = _selectedPreset?.bin;
    if (bin == null) return seg;
    if (seg.isEmpty) return bin;
    return '$bin-$seg';
  }

  void _syncDefaultName() {
    if (_nameEdited) return;
    _nameController.text = _defaultName();
  }

  void _syncDefaultWorkspaceName() {
    if (_workspaceNameEdited) return;
    _workspaceNameController.text = lastPathSegment(_cwdController.text.trim());
  }

  void _syncDefaultNames() {
    _syncDefaultName();
    _syncDefaultWorkspaceName();
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

  // Gates the launch button on the non-text prerequisites only (a preset, and
  // in existing mode a chosen workspace). Empty text fields are surfaced as
  // inline validator messages on launch instead of silently disabling the
  // button, so the user can see why nothing happens.
  bool get _canLaunch {
    if (_busy) return false;
    if (_selectedPreset == null) return false;
    if (_mode == _WorkspaceMode.existing && _selectedWorkspaceId == null) {
      return false;
    }
    return true;
  }

  Future<void> _launch() async {
    final preset = _selectedPreset;
    if (preset == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
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
      final name = _nameController.text.trim().isEmpty
          ? preset.bin
          : _nameController.text.trim();
      final workspace = _mode == _WorkspaceMode.newWorkspace
          ? await widget.client.createWorkspace(
              label: _workspaceNameController.text.trim(),
              cwd: cwd,
            )
          : null;
      final wsId = workspace?.workspaceId ?? _selectedWorkspaceId!;
      String? splitPaneId;
      try {
        final paneId =
            workspace?.paneId ??
            (splitPaneId = await widget.client.splitPane(
              workspaceId: wsId,
              cwd: cwd,
            ));
        await widget.client.startAgent(
          name: name,
          kind: preset.kind,
          paneId: paneId,
        );
      } catch (e) {
        if (_mode == _WorkspaceMode.newWorkspace) {
          try {
            await widget.client.closeWorkspace(wsId);
          } catch (_) {}
        } else if (splitPaneId != null) {
          try {
            await widget.client.closeAgent(splitPaneId);
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
        _launchError = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    // Self-decorate: the caller opens us via a plain showModalBottomSheet, so
    // the rounded top + grab handle live here rather than at the call site.
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
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
                  Text(
                    l10n.commonLaunchAgent,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  _buildPresetSection(),
                  const SizedBox(height: 16),
                  _buildCwdSection(),
                  const SizedBox(height: 16),
                  _buildNameSection(),
                  const SizedBox(height: 16),
                  _buildWorkspaceSection(),
                  if (_launchError != null) ...[
                    const SizedBox(height: 12),
                    ErrorMessageView(_launchError!),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('launch_cancel_button'),
                          style: droverNeutralButtonStyle(scheme),
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(context, false),
                          child: Text(l10n.commonCancel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('launch_button'),
                          onPressed: _canLaunch ? _launch : null,
                          child: _busy
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  droverLabelText(context, l10n.launchButton),
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
          ),
        ),
      ),
    );
  }

  Widget _buildPresetSection() {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<List<AgentPreset>>(
      future: _presetsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // 36: CircularProgressIndicator's natural size, so it isn't
          // squashed into an oval while reserving space for the chip row.
          return const SizedBox(
            height: 36,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ErrorMessageView(snapshot.error!),
              TextButton(
                onPressed: () => setState(_detectAgents),
                child: Text(l10n.commonRetry),
              ),
            ],
          );
        }
        final presets = snapshot.data ?? [];
        if (presets.isEmpty) {
          return Text(l10n.launchNoAgents);
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in presets)
              ChoiceChip(
                key: ValueKey('preset_${preset.bin}'),
                label: Text(preset.label),
                selected: preset == _selectedPreset,
                onSelected: (_) {
                  if (_busy) return;
                  setState(() {
                    _selectedPreset = preset;
                    _syncDefaultName();
                  });
                },
              ),
          ],
        );
      },
    );
  }

  Future<void> _browseCwd() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DirectoryPickerSheet(
          client: widget.client,
          initialPath: _cwdController.text.trim(),
        ),
      ),
    );
    if (!mounted) return;
    if (picked != null && picked.isNotEmpty) {
      setState(() {
        _cwdController.text = picked;
        _syncDefaultNames();
      });
    }
  }

  Widget _buildCwdSection() {
    final l10n = AppLocalizations.of(context)!;
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
                  // The label ramp, but no uppercasing: a directory segment
                  // is case-sensitive.
                  labelStyle: droverLabelStyle(
                    context,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  label: Text(lastPathSegment(cwd)),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _cwdController.text = cwd;
                          _syncDefaultNames();
                        }),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        TextFormField(
          key: const ValueKey('cwd_field'),
          controller: _cwdController,
          enabled: !_busy,
          contextMenuBuilder: noScanTextContextMenuBuilder,
          decoration: InputDecoration(
            labelText: l10n.launchWorkingDir,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              key: const ValueKey('cwd_browse_button'),
              tooltip: l10n.launchBrowseDir,
              onPressed: _busy ? null : _browseCwd,
              icon: const Icon(Icons.folder_open),
            ),
          ),
          validator: (v) => (v == null || v.trim().isEmpty)
              ? l10n.launchWorkingDirRequired
              : null,
          onChanged: (_) => setState(_syncDefaultNames),
        ),
      ],
    );
  }

  Widget _buildNameSection() {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      key: const ValueKey('agent_name_field'),
      controller: _nameController,
      enabled: !_busy,
      contextMenuBuilder: noScanTextContextMenuBuilder,
      decoration: InputDecoration(
        labelText: l10n.launchAgentName,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) {
        _nameEdited = true;
        setState(() {});
      },
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
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<_WorkspaceMode>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _WorkspaceMode.newWorkspace,
              label: KeyedSubtree(
                key: const ValueKey('ws_mode_new'),
                child: Text(l10n.launchNewWorkspace),
              ),
            ),
            ButtonSegment(
              value: _WorkspaceMode.existing,
              label: KeyedSubtree(
                key: const ValueKey('ws_mode_existing'),
                child: Text(l10n.launchExistingWorkspace),
              ),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (values) => _selectMode(values.first),
        ),
        if (_mode == _WorkspaceMode.newWorkspace) ...[
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('workspace_name_field'),
            controller: _workspaceNameController,
            enabled: !_busy,
            contextMenuBuilder: noScanTextContextMenuBuilder,
            decoration: InputDecoration(
              labelText: l10n.launchWorkspaceName,
              border: const OutlineInputBorder(),
            ),
            validator: (v) => (v == null || v.trim().isEmpty)
                ? l10n.launchWorkspaceNameRequired
                : null,
            onChanged: (_) {
              _workspaceNameEdited = true;
              setState(() {});
            },
          ),
        ],
        if (_mode == _WorkspaceMode.existing) ...[
          const SizedBox(height: 12),
          _buildWorkspaceDropdown(),
        ],
      ],
    );
  }

  Widget _buildWorkspaceDropdown() {
    final l10n = AppLocalizations.of(context)!;
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
              ErrorMessageView(snapshot.error!),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(_loadWorkspaces),
                    child: Text(l10n.commonRetry),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _mode = _WorkspaceMode.newWorkspace;
                    }),
                    child: Text(l10n.launchUseNewWorkspace),
                  ),
                ],
              ),
            ],
          );
        }
        final workspaces = snapshot.data ?? [];
        if (workspaces.isEmpty) {
          return Text(l10n.launchNoExistingWorkspaces);
        }
        final labelCounts = <String, int>{};
        for (final workspace in workspaces) {
          final label = workspace.label.trim();
          if (label.isNotEmpty) {
            labelCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
          }
        }
        return DropdownButton<String>(
          key: const ValueKey('ws_dropdown'),
          isExpanded: true,
          hint: Text(l10n.launchSelectWorkspace),
          value: _selectedWorkspaceId,
          items: [
            for (final ws in workspaces)
              DropdownMenuItem(
                value: ws.workspaceId,
                child: Text(_workspaceDisplayLabel(ws, labelCounts, l10n)),
              ),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() => _selectedWorkspaceId = value),
        );
      },
    );
  }

  String _workspaceDisplayLabel(
    WorkspaceInfo workspace,
    Map<String, int> labelCounts,
    AppLocalizations l10n,
  ) {
    final label = workspace.label.trim();
    if (label.isEmpty) {
      return l10n.launchUnnamedWorkspace(workspace.workspaceId);
    }
    if (labelCounts[label]! > 1) {
      return '$label (${workspace.workspaceId})';
    }
    return label;
  }
}
