import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../i18n/status_label.dart';
import '../models/agent_info.dart';

/// A rounded-rect avatar for an agent, filled with the agent type's brand
/// color and stamped with a single initial (claude→C, codex→X, copilot→P,
/// pi→π; otherwise the first letter of the type, or `?` when unknown). Gives
/// each agent a recognizable "face" in lists and the switcher bar.
///
/// With a [status], the face also carries the agent's state: a solid ring when
/// blocked, a moving dashed ring while working, a thin ring when done, and a
/// dimmed face otherwise. The ring space ([ringInset] per side) is reserved
/// whenever [status] is set, so the footprint doesn't change with the state.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.agent,
    this.size = 40,
    this.radius = droverRadiusMedium,
    this.status,
  });

  /// Gap plus ring stroke, reserved on every side when [status] is set.
  static const double ringInset = _ringGap + _ringStroke;
  static const double _ringGap = 2;
  static const double _ringStroke = 2;

  /// Agent type (e.g. `claude`, `codex`, `copilot`, `pi`); null when unknown.
  final String? agent;
  final double size;
  final double radius;

  /// The agent's state; null renders the bare face (no ring, full opacity).
  final AgentStatus? status;

  String get _initial {
    switch (agent?.toLowerCase()) {
      case 'claude':
        return 'C';
      case 'codex':
        return 'X';
      case 'copilot':
        return 'P';
      // Not the fallback's `P` — that would collide with copilot.
      case 'pi':
        return 'π';
    }
    final type = agent?.trim();
    if (type == null || type.isEmpty) return '?';
    return type[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    final face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.brandColor(agent),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        _initial,
        style: TextStyle(
          color: colors.avatarFg,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
        ),
      ),
    );
    final status = this.status;
    if (status == null) return face;

    final color = colors.statusDot(status);
    final Widget decorated = switch (status) {
      AgentStatus.blocked => CustomPaint(
        foregroundPainter: _RingPainter(color, _ringStroke, radius),
        child: Padding(padding: const EdgeInsets.all(ringInset), child: face),
      ),
      AgentStatus.done => CustomPaint(
        foregroundPainter: _RingPainter(color, 1, radius),
        child: Padding(padding: const EdgeInsets.all(ringInset), child: face),
      ),
      AgentStatus.working => _WorkingRing(
        color: color,
        stroke: _ringStroke,
        radius: radius,
        child: Padding(padding: const EdgeInsets.all(ringInset), child: face),
      ),
      AgentStatus.idle || AgentStatus.unknown => Padding(
        padding: const EdgeInsets.all(ringInset),
        child: Opacity(opacity: 0.55, child: face),
      ),
    };
    return Semantics(
      label: agentStatusLabel(AppLocalizations.of(context)!, status),
      // The initial is decorative; the status is what's worth announcing.
      excludeSemantics: true,
      child: decorated,
    );
  }
}

/// The working ring: dashes that march around the face. Static (phase 0)
/// when the platform asks for reduced motion.
class _WorkingRing extends StatefulWidget {
  const _WorkingRing({
    required this.color,
    required this.stroke,
    required this.radius,
    required this.child,
  });

  final Color color;
  final double stroke;
  final double radius;
  final Widget child;

  @override
  State<_WorkingRing> createState() => _WorkingRingState();
}

class _WorkingRingState extends State<_WorkingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _RingPainter(
        widget.color,
        widget.stroke,
        widget.radius,
        dashPhase: _controller,
      ),
      child: widget.child,
    );
  }
}

/// Strokes a rounded-rect ring along the outer edge of the paint bounds,
/// concentric with a face of corner [radius] inset by [AgentAvatar.ringInset].
/// With [dashPhase] the ring is dashed and the dashes are offset by that
/// fraction of the perimeter.
class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.stroke, this.radius, {this.dashPhase})
    : super(repaint: dashPhase);

  final Color color;
  final double stroke;
  final double radius;
  final Animation<double>? dashPhase;

  static const int _dashes = 8;

  @override
  void paint(Canvas canvas, Size size) {
    // Hug the outer edge of the reserved inset; the face's corner radius
    // grows by the distance from the face to the stroke's midline.
    final inset = stroke / 2;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(inset),
      Radius.circular(radius + AgentAvatar.ringInset - inset),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final phase = dashPhase;
    if (phase == null) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    final PathMetric metric = (Path()..addRRect(rrect)).computeMetrics().first;
    final period = metric.length / _dashes;
    final offset = phase.value * metric.length;
    for (var i = 0; i < _dashes; i++) {
      final start = (offset + i * period) % metric.length;
      final end = start + period * 0.55;
      canvas.drawPath(metric.extractPath(start, end), paint);
      if (end > metric.length) {
        canvas.drawPath(metric.extractPath(0, end - metric.length), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color ||
      old.stroke != stroke ||
      old.radius != radius ||
      old.dashPhase != dashPhase;
}
