import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../i18n/status_label.dart';
import '../models/agent_info.dart';

/// A rounded-rect avatar for an agent: the agent's mark (the same ones the
/// herdr desktop app uses) centred on a neutral tile, or a bot glyph for an
/// unrecognised type. Gives each agent a recognizable "face" in lists and the
/// switcher bar.
///
/// With a [status], the face also carries the agent's state: a solid ring when
/// blocked, a comet arc lapping a faint track while working, a thin ring when done, and a
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

  /// Agents with a bundled mark under `assets/agents/`. Colour marks are drawn
  /// as-is; monochrome ones are white masks tinted to the theme's ink.
  static const _colorMarks = {'claude', 'codex'};
  static const _monoMarks = {'copilot', 'pi'};

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = agent?.toLowerCase();
    final markSize = size * 0.6;
    final mark = _colorMarks.contains(type) || _monoMarks.contains(type)
        ? Image.asset(
            'assets/agents/$type.png',
            width: markSize,
            height: markSize,
            fit: BoxFit.contain,
            color: _monoMarks.contains(type) ? scheme.onSurface : null,
            colorBlendMode: BlendMode.srcIn,
            semanticLabel: agent,
          )
        : Icon(
            Icons.smart_toy_outlined,
            size: markSize,
            color: scheme.onSurfaceVariant,
            semanticLabel: agent,
          );
    final face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: mark,
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
      // The mark is decorative; the status is what's worth announcing.
      excludeSemantics: true,
      child: decorated,
    );
  }
}

/// The working ring: a comet arc that laps a faint track around the face.
/// Static (phase 0) when the platform asks for reduced motion.
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
    duration: const Duration(milliseconds: 1800),
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
        cometPhase: _controller,
      ),
      child: widget.child,
    );
  }
}

/// Strokes a rounded-rect ring along the outer edge of the paint bounds,
/// concentric with a face of corner [radius] inset by [AgentAvatar.ringInset].
/// With [cometPhase] the ring becomes a faint track plus a comet (a solid
/// head and a fainter tail) whose head sits at that fraction of the perimeter.
class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.stroke, this.radius, {this.cometPhase})
    : super(repaint: cometPhase);

  final Color color;
  final double stroke;
  final double radius;
  final Animation<double>? cometPhase;

  // Fractions of the perimeter.
  static const double _head = 0.18;
  static const double _tail = 0.30;

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
    final phase = cometPhase;
    if (phase == null) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    canvas.drawRRect(rrect, paint..color = color.withValues(alpha: 0.18));
    final PathMetric metric = (Path()..addRRect(rrect)).computeMetrics().first;
    final length = metric.length;
    final front = (phase.value + _head) * length;
    void arc(double fraction, double alpha) {
      final start = (front - fraction * length) % length;
      final end = start + fraction * length;
      paint.color = color.withValues(alpha: alpha);
      canvas.drawPath(metric.extractPath(start, end), paint);
      if (end > length) {
        canvas.drawPath(metric.extractPath(0, end - length), paint);
      }
    }

    arc(_tail, 0.35);
    arc(_head, 1);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color ||
      old.stroke != stroke ||
      old.radius != radius ||
      old.cometPhase != cometPhase;
}
