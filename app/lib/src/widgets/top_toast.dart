import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shows a transient notification that slides in from the top of the screen.
///
/// The app's bottom edge is occupied by the agent composer and action bar, so
/// bottom-anchored `SnackBar`s cover the input. Top toasts keep that area
/// clear. Multiple toasts stack vertically and each auto-dismisses; tapping a
/// toast dismisses it early.
void showTopToast(BuildContext context, String message) {
  _managerFor(Overlay.of(context)).show(message);
}

/// Like [showTopToast] but driven by an [OverlayState] directly instead of
/// resolving one from a [BuildContext].
///
/// App-level callers (the global notification callbacks in `main.dart`) only
/// hold the root navigator key. Its `currentContext` is the `Navigator`
/// widget's own context, and a `Navigator`'s [Overlay] is a *descendant* of
/// it — so `Overlay.of(navigatorContext)` finds no overlay ancestor and
/// throws "No Overlay widget found". Those callers pass
/// `navigatorKey.currentState!.overlay` here instead.
void showTopToastOnOverlay(OverlayState overlay, String message) {
  _managerFor(overlay).show(message);
}

final Expando<_ToastManager> _managers = Expando('topToastManager');

_ToastManager _managerFor(OverlayState overlay) =>
    _managers[overlay] ??= _ToastManager(overlay);

class _ToastManager {
  _ToastManager(this.overlay);

  final OverlayState overlay;
  final List<_ToastData> _toasts = [];
  final ValueNotifier<List<_ToastData>> _notifier = ValueNotifier(const []);
  OverlayEntry? _entry;
  int _nextId = 0;

  void show(String message) {
    _toasts.add(_ToastData(id: _nextId++, message: message));
    _notifier.value = List.unmodifiable(_toasts);
    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (_) => _ToastStack(notifier: _notifier, onDismissed: _remove),
      );
      overlay.insert(_entry!);
    }
  }

  void _remove(int id) {
    _toasts.removeWhere((t) => t.id == id);
    _notifier.value = List.unmodifiable(_toasts);
    if (_toasts.isEmpty) {
      _entry?.remove();
      _entry = null;
    }
  }
}

class _ToastData {
  const _ToastData({required this.id, required this.message});

  final int id;
  final String message;
}

class _ToastStack extends StatelessWidget {
  const _ToastStack({required this.notifier, required this.onDismissed});

  final ValueListenable<List<_ToastData>> notifier;
  final void Function(int id) onDismissed;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<List<_ToastData>>(
          valueListenable: notifier,
          builder: (_, toasts, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in toasts)
                _ToastCard(
                  key: ValueKey(t.id),
                  message: t.message,
                  onDismissed: () => onDismissed(t.id),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({
    super.key,
    required this.message,
    required this.onDismissed,
  });

  final String message;
  final VoidCallback onDismissed;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  static const _visibleDuration = Duration(seconds: 3);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _timer = Timer(_visibleDuration, _dismiss);
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _curved,
      child: SizeTransition(
        sizeFactor: _curved,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            color: scheme.inverseSurface,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _dismiss,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    widget.message,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onInverseSurface),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
