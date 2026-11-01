import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../i18n/status_label.dart';
import '../models/agent_info.dart';

/// The small trailing marker for an agent's state, after the herdr desktop
/// app: a spinner while working, a "Needs you" pill when blocked, a filled dot
/// when done, and a hollow ring when idle or unknown. Announces the state to
/// screen readers in place of its drawing.
class AgentStatusIndicator extends StatelessWidget {
  const AgentStatusIndicator({super.key, required this.status, this.size = 16});

  final AgentStatus status;

  /// Side of the spinner's box.
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DroverColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final color = colors.statusDot(status);
    final Widget child = switch (status) {
      AgentStatus.working => _Spinner(color: color, size: size),
      AgentStatus.blocked => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: colors.statusPillBg(AgentStatus.blocked),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          l10n.herdNeedsYouLabel,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: colors.statusPillFg(AgentStatus.blocked),
          ),
        ),
      ),
      AgentStatus.done => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      AgentStatus.idle || AgentStatus.unknown => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
      ),
    };
    return Semantics(
      label: agentStatusLabel(l10n, status),
      excludeSemantics: true,
      child: child,
    );
  }
}

/// A quarter arc lapping a faint track, one turn per 900 ms. Static when the
/// platform asks for reduced motion.
class _Spinner extends StatefulWidget {
  const _Spinner({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
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
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(widget.size),
    painter: SpinnerPainter(widget.color, _controller),
  );
}

/// herdr's spinner SVG scaled from its 24-unit viewBox: an r=9.4 track at
/// 0.24 alpha plus a 12-to-3 o'clock arc, stroke 3.2, rotated by [turn].
@visibleForTesting
class SpinnerPainter extends CustomPainter {
  SpinnerPainter(this.color, this.turn) : super(repaint: turn);

  final Color color;
  final Animation<double> turn;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2 * scale
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.24);
    final rect = Rect.fromCircle(center: center, radius: 9.4 * scale);
    canvas.drawCircle(center, 9.4 * scale, paint);
    canvas.drawArc(
      rect,
      -math.pi / 2 + turn.value * 2 * math.pi,
      math.pi / 2,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(SpinnerPainter old) =>
      old.color != color || old.turn != turn;
}
