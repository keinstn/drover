import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../models/agent_info.dart';
import 'agent_avatar.dart';

/// The 案D switcher bar: a fixed 一覧 (Herd) tab followed by every running
/// agent, so the user can see each agent's status and switch between them
/// without leaving the conversation. Visible only when 2+ agents are running;
/// below that it slides out and collapses to just the home-indicator inset,
/// and slides back in (translateY + fade, ~240ms ease-out) when another agent
/// appears.
class AgentSwitcherBar extends StatefulWidget {
  const AgentSwitcherBar({
    super.key,
    required this.agents,
    required this.currentPaneId,
    required this.onSelect,
    required this.onOpenHerd,
  });

  final List<AgentInfo> agents;

  /// The agent this bar is shown *from*, ringed and accented as "current".
  final String currentPaneId;

  final void Function(AgentInfo agent) onSelect;
  final VoidCallback onOpenHerd;

  @override
  State<AgentSwitcherBar> createState() => _AgentSwitcherBarState();
}

class _AgentSwitcherBarState extends State<AgentSwitcherBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;

  bool get _visible => widget.agents.length >= 2;

  static String _displayName(AgentInfo agent) =>
      agent.sessionTitle ?? agent.name ?? agent.agent ?? agent.paneId;

  /// The bar label: the session title (or fallback) shortened to 6 code points
  /// + '…' once it exceeds 7 (the spec's rule), rune-safe for multibyte text.
  static String _shortLabel(String text) {
    final runes = text.runes.toList();
    if (runes.length <= 7) return text;
    return '${String.fromCharCodes(runes.take(6))}…';
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: _visible ? 1 : 0,
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  }

  @override
  void didUpdateWidget(AgentSwitcherBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Slide in on 1→2, slide out on 2→1; both no-op when already settled.
    if (_visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, _) {
        final t = _curve.value.clamp(0.0, 1.0);
        // Settled hidden: the bar is gone entirely (no children in the tree),
        // leaving only the home-indicator inset so whatever sits above it (the
        // composer, or the transcript when the composer is hidden) keeps its
        // clearance.
        if (t == 0 && !_visible) {
          return SizedBox(width: double.infinity, height: bottomInset);
        }
        // The bar body's reserved height animates via the heightFactor while
        // its content translates up from below and fades in; a
        // shrinking spacer keeps the total bottom clearance ≈ the inset
        // throughout the transition (the body carries the inset itself once
        // fully in).
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: t,
                child: Opacity(
                  opacity: t,
                  child: FractionalTranslation(
                    translation: Offset(0, 1 - t),
                    child: _bar(context, bottomInset),
                  ),
                ),
              ),
            ),
            SizedBox(height: (1 - t) * bottomInset),
          ],
        );
      },
    );
  }

  Widget _bar(BuildContext context, double bottomInset) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(14, 9, 14, 9 + bottomInset),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _herdTab(context),
            for (final agent in widget.agents) ...[
              const SizedBox(width: 14),
              _agentItem(context, agent),
            ],
          ],
        ),
      ),
    );
  }

  Widget _herdTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    return _BarCell(
      key: const ValueKey('switcher_herd_tab'),
      onTap: widget.onOpenHerd,
      box: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(droverRadiusMedium),
          border: Border.all(color: scheme.outline, width: 1.5),
        ),
        child: Icon(Icons.grid_view, size: 20, color: scheme.onSurfaceVariant),
      ),
      label: l10n.agentSwitcherHerdTab,
      labelColor: colors.tertiaryText,
    );
  }

  Widget _agentItem(BuildContext context, AgentInfo agent) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DroverColors.of(context);
    final isCurrent = agent.paneId == widget.currentPaneId;
    return _BarCell(
      key: ValueKey('switcher_agent_${agent.paneId}'),
      onTap: isCurrent ? null : () => widget.onSelect(agent),
      box: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              // The ring paints over the avatar's edge, so current/other keep
              // the same 44px footprint (only the border colour differs).
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(droverRadiusMedium),
                border: Border.all(
                  // accentText: under ink this is full-strength onSurface,
                  // which is the clearest "current" mark the palette has —
                  // 14.12:1 on this switcher ground. Selection is the one role
                  // the hueless accent is better at than a coloured one.
                  color: isCurrent ? colors.accentText : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: AgentAvatar(
                agent: agent.agent,
                size: 44,
                radius: droverRadiusMedium,
              ),
            ),
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                width: 12,
                height: 12,
                // Round, matching StatusPill's dot: a bullet rather than an
                // LED.
                decoration: BoxDecoration(
                  color: colors.statusDot(agent.status),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.surfaceContainerLow,
                    width: 2.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      label: _shortLabel(_displayName(agent)),
      labelColor: isCurrent ? colors.accentText : colors.tertiaryText,
    );
  }
}

/// One switcher-bar entry: a 44×44 box (avatar or the 一覧 tile) above a 9px
/// label, tappable as a unit.
class _BarCell extends StatelessWidget {
  const _BarCell({
    super.key,
    required this.box,
    required this.label,
    required this.labelColor,
    required this.onTap,
  });

  final Widget box;
  final String label;
  final Color labelColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          box,
          const SizedBox(height: 4),
          SizedBox(
            width: 52,
            child: Text(
              // Not through `droverLabelText`: the bar label comes from the
              // agent's user-chosen session title or name.
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: droverLabelStyle(context, fontSize: 9, color: labelColor),
            ),
          ),
        ],
      ),
    );
  }
}
