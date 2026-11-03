import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../herdr/agent_name.dart';
import '../herdr/hc_client.dart';
import '../herdr/herdr_backend.dart';
import '../herdr/herdr_client.dart';
import '../models/agent_preset.dart';
import '../models/workspace_info.dart';
import '../utils/path.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/error_message_view.dart';
import '../widgets/text_context_menu.dart';
import 'directory_picker_sheet.dart';

enum _WorkspaceMode { newWorkspace, existing }

const _sheetPadding = 16.0;

/// The backend last launched on per client, for this app session.
final _lastBackend = Expando<HerdrBackend>();
const _tileHeight = 76.0;

/// Sheet body for launching a new agent: pick a preset, a cwd, and whether to
/// place it in a new or existing workspace. Pops the launched agent's pane id,
/// or nothing when cancelled.
class LaunchAgentSheet extends StatefulWidget {
  const LaunchAgentSheet({
    super.key,
    required this.client,
    required this.existingCwds,
    this.backends,
    this.herdrTooOld,
  });

  final HerdrClient client;
  final List<String> existingCwds;

  /// What [client] reaches ([HerdrClient.availableBackends], already awaited
  /// by the caller); the switch shows when it's both. Null means
  /// [HerdrClient.backend] alone.
  final List<HerdrBackend>? backends;

  /// Checked before a herdr 1 launch when the sheet offers both backends;
  /// true blocks it (the caller shows why). With one backend the caller
  /// gates before opening the sheet instead.
  final Future<bool> Function()? herdrTooOld;

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

  late final List<HerdrBackend> _backends =
      widget.backends ?? [widget.client.backend];

  /// The remembered choice when still offered, else the first.
  late HerdrBackend _backend = switch (_lastBackend[widget.client]) {
    final last? when _backends.contains(last) => last,
    _ => _backends.firstOrNull ?? widget.client.backend,
  };

  /// The single-backend client the launch runs against.
  HerdrClient get _part => widget.client.clientFor(_backend);

  /// Herdr 2 can only launch into a space that already exists in the app:
  /// no new-workspace mode, no split, no `agent start`.
  bool get _isHc => _backend == HerdrBackend.hc;

  @override
  void initState() {
    super.initState();
    _detectAgents();
    _applyBackend();
  }

  void _applyBackend() {
    _selectedWorkspaceId = null;
    _workspacesFuture = null;
    _mode = _isHc ? _WorkspaceMode.existing : _WorkspaceMode.newWorkspace;
    if (_isHc) _loadWorkspaces();
  }

  void _selectBackend(HerdrBackend backend) {
    _lastBackend[widget.client] = backend;
    setState(() {
      _backend = backend;
      _launchError = null;
      _applyBackend();
    });
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

  /// The name the field starts with — slugged, so what it shows is a name
  /// `herdr agent start` will actually accept (a `MyProject` or `案件` folder
  /// would otherwise fail the launch with `invalid_agent_name`).
  String _defaultName() {
    final seg = lastPathSegment(_cwdController.text.trim());
    final bin = _selectedPreset?.bin;
    if (bin == null) return seg.isEmpty ? '' : agentNameSlug(seg);
    if (seg.isEmpty) return bin;
    return agentNameSlug('$bin-$seg');
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
    final future = _part.listWorkspaces();
    _workspacesFuture = future;
    future.then((workspaces) {
      // A stale list from before a backend switch.
      if (!mounted || !identical(future, _workspacesFuture)) return;
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
    // Busy before any await: no second Launch tap, no backend switch.
    setState(() {
      _busy = true;
      _launchError = null;
    });
    if (!_isHc && await widget.herdrTooOld?.call() == true) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    try {
      final name = _nameController.text.trim().isEmpty
          ? preset.bin
          : _nameController.text.trim();
      if (_isHc) {
        final paneId = await (_part as HcClient).runAgent(
          argv: [preset.bin],
          cwd: cwd,
          spaceId: _selectedWorkspaceId!,
          name: name,
        );
        if (!mounted) return;
        Navigator.pop(context, paneId);
        return;
      }
      final workspace = _mode == _WorkspaceMode.newWorkspace
          ? await _part.createWorkspace(
              label: _workspaceNameController.text.trim(),
              cwd: cwd,
            )
          : null;
      final wsId = workspace?.workspaceId ?? _selectedWorkspaceId!;
      String? splitPaneId;
      final String paneId;
      try {
        paneId =
            workspace?.paneId ??
            (splitPaneId = await _part.splitPane(workspaceId: wsId, cwd: cwd));
        // Slugs a hand-typed illegal name and walks past one a live agent
        // already holds. It stays inside this try so a taken name is not
        // mistaken for a failed start and does not roll the pane back.
        // An agent blocked at a startup prompt (`ready: false`) is kept too:
        // the agent screen it pops to is where the user answers that prompt.
        await startAgentWithFreeName(
          base: name,
          start: (name) =>
              _part.startAgent(name: name, kind: preset.kind, paneId: paneId),
        );
      } catch (e) {
        if (_mode == _WorkspaceMode.newWorkspace) {
          try {
            await _part.closeWorkspace(wsId);
          } catch (_) {}
        } else if (splitPaneId != null) {
          try {
            await _part.closeAgent(splitPaneId);
          } catch (_) {}
        }
        rethrow;
      }
      if (!mounted) return;
      Navigator.pop(context, paneId);
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
        // The padding sits inside the scroll view so the agent row can bleed
        // past it to the sheet's edges without being clipped.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(_sheetPadding),
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
                if (_backends.length > 1) ...[
                  SegmentedButton<HerdrBackend>(
                    key: const ValueKey('launch_backend_switch'),
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: HerdrBackend.herdr,
                        label: Text(l10n.herdHerdr1Tag),
                      ),
                      ButtonSegment(
                        value: HerdrBackend.hc,
                        label: Text(l10n.herdHerdr2Tag),
                      ),
                    ],
                    selected: {_backend},
                    onSelectionChanged: _busy
                        ? null
                        : (values) => _selectBackend(values.first),
                  ),
                  const SizedBox(height: 16),
                ],
                _buildPresetSection(),
                const SizedBox(height: 16),
                _buildCwdSection(),
                const SizedBox(height: 16),
                _buildNameSection(),
                const SizedBox(height: 16),
                _isHc ? _buildSpaceSection() : _buildWorkspaceSection(),
                if (_launchError != null) ...[
                  const SizedBox(height: 12),
                  ErrorMessageView(_launchError!),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        key: const ValueKey('launch_cancel_button'),
                        style: droverNeutralButtonStyle(scheme),
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        child: Text(l10n.commonCancel),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
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
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  droverLabelText(
                                    context,
                                    _selectedPreset == null
                                        ? l10n.launchButton
                                        : l10n.launchAgentButton(
                                            _selectedPreset!.label,
                                          ),
                                  ),
                                  maxLines: 1,
                                  style: droverLabelStyle(
                                    context,
                                    fontSize: 11.5,
                                    weight: FontWeight.w700,
                                  ),
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
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      droverLabelText(context, text),
      style: droverLabelStyle(
        context,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        weight: FontWeight.w700,
      ),
    ),
  );

  Widget _buildPresetSection() {
    final l10n = AppLocalizations.of(context)!;
    final presets = FutureBuilder<List<AgentPreset>>(
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
        // One row that scrolls sideways, bled out to the sheet's edges so a
        // tile that doesn't fit is visibly cut off there. The initial pick is
        // always the first tile, so it starts in view without scrolling.
        return LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            height: _tileHeight,
            child: OverflowBox(
              maxWidth: constraints.maxWidth + 2 * _sheetPadding,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: _sheetPadding),
                itemCount: presets.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _presetTile(presets[i]),
              ),
            ),
          ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_sectionLabel(l10n.launchSectionAgent), presets],
    );
  }

  Widget _presetTile(AgentPreset preset) {
    final scheme = Theme.of(context).colorScheme;
    final selected = preset == _selectedPreset;
    void select() {
      if (_busy) return;
      setState(() {
        _selectedPreset = preset;
        _syncDefaultName();
      });
    }

    return Semantics(
      selected: selected,
      button: true,
      label: preset.label,
      onTap: select,
      excludeSemantics: true,
      child: Material(
        key: ValueKey('preset_${preset.bin}'),
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? BorderSide(color: scheme.onSurface, width: 2)
              : BorderSide(color: scheme.outline),
        ),
        child: InkWell(
          onTap: select,
          child: SizedBox(
            width: 66,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AgentAvatar(agent: preset.kind, size: 36),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    preset.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
    final scheme = Theme.of(context).colorScheme;
    final current = _cwdController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.launchWorkingDir),
        TextFormField(
          key: const ValueKey('cwd_field'),
          controller: _cwdController,
          enabled: !_busy,
          contextMenuBuilder: noScanTextContextMenuBuilder,
          decoration: InputDecoration(
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
        if (widget.existingCwds.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  l10n.launchRecent,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                for (final cwd in widget.existingCwds) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    key: ValueKey('recent_cwd_$cwd'),
                    // The label ramp, but no uppercasing: a directory segment
                    // is case-sensitive.
                    labelStyle: droverLabelStyle(
                      context,
                      color: scheme.onSurface,
                    ),
                    backgroundColor: cwd == current
                        ? scheme.surfaceContainerHighest
                        : null,
                    side: cwd == current
                        ? BorderSide(color: scheme.onSurface)
                        : null,
                    label: Text(lastPathSegment(cwd)),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _cwdController.text = cwd;
                            _syncDefaultNames();
                          }),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNameSection() {
    final l10n = AppLocalizations.of(context)!;
    final field = TextField(
      key: const ValueKey('agent_name_field'),
      controller: _nameController,
      enabled: !_busy,
      contextMenuBuilder: noScanTextContextMenuBuilder,
      decoration: const InputDecoration(border: OutlineInputBorder()),
      onChanged: (_) {
        _nameEdited = true;
        setState(() {});
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_sectionLabel(l10n.launchSectionName), field],
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
        _sectionLabel(l10n.launchSectionWorkspace),
        SegmentedButton<_WorkspaceMode>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _WorkspaceMode.newWorkspace,
              label: KeyedSubtree(
                key: const ValueKey('ws_mode_new'),
                child: Text(l10n.launchModeNew),
              ),
            ),
            ButtonSegment(
              value: _WorkspaceMode.existing,
              label: KeyedSubtree(
                key: const ValueKey('ws_mode_existing'),
                child: Text(l10n.launchModeExisting),
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

  Widget _buildSpaceSection() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.launchSectionSpace),
        _buildWorkspaceDropdown(),
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
                  if (!_isHc)
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
          return _isHc
              ? Text(
                  l10n.launchNoSpaces,
                  key: const ValueKey('launch_no_spaces'),
                )
              : Text(l10n.launchNoExistingWorkspaces);
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
          hint: Text(
            _isHc ? l10n.launchSelectSpace : l10n.launchSelectWorkspace,
          ),
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
      return _isHc
          ? l10n.launchUnnamedSpace(displayId(workspace.workspaceId))
          : l10n.launchUnnamedWorkspace(workspace.workspaceId);
    }
    if (labelCounts[label]! > 1) {
      return '$label (${displayId(workspace.workspaceId)})';
    }
    return label;
  }
}
