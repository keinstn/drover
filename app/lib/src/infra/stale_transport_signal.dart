import 'dart:async';

import 'network_change_signal.dart';

/// Fans in the two independent reasons cached SSH transport state can go
/// stale — an OS network-interface change ([NetworkChangeSignal]) and the app
/// returning to the foreground after iOS tears down a suspended app's sockets
/// — into one coalesced signal for `main.dart` to invalidate the connection
/// registry on.
///
/// Both sources are debounced on the TRAILING edge (~1s): a resume and the
/// connectivity events that accompany the very same Wi-Fi transition would
/// otherwise fire as two separate invalidations, and the second one would
/// discard the reconnect the first one's poll tick just kicked off (via the
/// runner's generation guard) — producing the exact error flash this signal
/// exists to prevent. One settled event per real-world transition.
///
/// Owns [network]: [dispose] disposes it too, so callers must not also
/// dispose the [NetworkChangeSignal] they pass in.
class StaleTransportSignal {
  StaleTransportSignal(
    this._network, {
    this._debounce = const Duration(seconds: 1),
  }) {
    _subscription = _network.changes.listen((_) => _schedule());
  }

  final NetworkChangeSignal _network;
  final Duration _debounce;
  final _controller = StreamController<void>.broadcast();
  late final StreamSubscription<void> _subscription;
  Timer? _timer;

  /// Emits once per settled transition from either source. Broadcast, so
  /// `main.dart` (registry invalidation) and [HerdScreen.networkChanges]
  /// (backoff reset) can each listen independently.
  Stream<void> get changes => _controller.stream;

  /// Marks the transport stale for a reason [NetworkChangeSignal] can't see
  /// on its own — `main.dart` calls this on `AppLifecycleState.resumed`.
  void markStale() => _schedule();

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_debounce, () => _controller.add(null));
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription.cancel();
    await _network.dispose();
    await _controller.close();
  }
}
