import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../screens/herd_screen.dart';
import 'demo_backend.dart';

/// Hosts the scripted demo session. [HerdScreen] runs inside its own
/// [Navigator] — [HerdScreen] pushes its `AgentScreen` route via
/// `Navigator.of(context)`, which resolves to the *nearest* ancestor, so
/// nesting it here keeps [_DemoBanner] visible above that pushed route too,
/// without needing any demo-specific branch in `agent_screen.dart`.
class DemoScreen extends StatefulWidget {
  const DemoScreen({
    super.key,
    required this.backend,
    required this.hasConfiguredHost,
    required this.onExitDemo,
    required this.onOpenSettings,
  });

  final DemoBackend backend;

  /// Gates the "Set up a connection" ending copy: an entry point that reaches
  /// the demo with hosts already configured (the settings entry) must not tell
  /// that user to set one up.
  final bool hasConfiguredHost;
  final VoidCallback onExitDemo;

  /// Opens the real settings screen. Theme and language are host-independent,
  /// so they work exactly as they do outside the demo — and picking a language
  /// is plausibly the first thing a new user wants. Pushed on the *root*
  /// navigator by main, not the inner one, so settings covers the demo banner
  /// like any other app-level screen.
  final VoidCallback onOpenSettings;

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final _innerNavKey = GlobalKey<NavigatorState>();
  late final _client = widget.backend.buildClient();

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_onBackendChanged);
  }

  void _onBackendChanged() => setState(() {});

  @override
  void dispose() {
    widget.backend.removeListener(_onBackendChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final host = HerdHostRef(
      hostId: demoHostId,
      displayName: l10n.demoHostDisplayName,
      revision: 0,
    );
    final showEnding = widget.backend.isComplete && !widget.hasConfiguredHost;
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Navigator(
              key: _innerNavKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                builder: (_) => HerdScreen(
                  hosts: [host],
                  clientFor: (_) => _client,
                  filterHostId: demoHostId,
                  // Null, not a no-op: the demo has no hosts, so there is
                  // nothing to switch between and the chip is hidden.
                  onOpenHostSwitcher: null,
                  onOpenSettings: widget.onOpenSettings,
                  // Same rule as the switcher chip above: only the scripted
                  // pane can act on a message, so only it shows a composer.
                  // The two scenery agents have no script behind them, and a
                  // composer there would swallow a message the user had
                  // already taken the trouble to type.
                  showComposerFor: (paneId) => paneId == demoPaneId,
                ),
              ),
            ),
          ),
          _DemoBanner(
            showEnding: showEnding,
            onExit: widget.onExitDemo,
            l10n: l10n,
          ),
        ],
      ),
    );
  }
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner({
    required this.showEnding,
    required this.onExit,
    required this.l10n,
  });

  final bool showEnding;
  final VoidCallback onExit;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (showEnding)
                Expanded(
                  child: Text(
                    l10n.demoBannerDoneCopy,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                const Spacer(),
              TextButton(
                key: const ValueKey('demo_exit_button'),
                onPressed: onExit,
                child: Text(
                  showEnding
                      ? l10n.demoBannerSetupConnection
                      : l10n.demoBannerExit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
